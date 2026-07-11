-- Миграция 006 — закрытие сезона одной транзакцией (задача G8)
--
-- Зачем RPC, а не цепочка запросов из teacher.html: закрытие сезона — единственная
-- операция этапа 1, которая массово пишет по всем ученикам разом (архив итогов →
-- награды топ-3 → обнуление очков → закрытие сезона). Выполненная как несколько
-- PostgREST-запросов из браузера, она может упасть на середине (сеть, закрытая
-- вкладка) и оставить БД в половинчатом состоянии, где повторный запуск раздал бы
-- награды второй раз — риск, прямо названный в карточке G8. Функция plpgsql
-- выполняется одной транзакцией: всё или ничего, частичный сбой невозможен по
-- построению. Прецедент паттерна — add_huikons (миграция 001).
--
-- Награды за место: 100/60/30 бубликов за топ-1/2/3 — сверено с таблицей доходов
-- GAME_DESIGN.md §5 («Место в сезоне (топ-3 лидерборда/лиги) | 100 / 60 / 30 |
-- Раз в 2 недели»), как требует карточка G8.
--
-- Принятые решения (зафиксированы здесь, чтобы не переоткрывать):
--   * Места считаются rank(): равные очки = одно место (1,2,2,4). При ничьей на
--     призовом месте награду получают ОБА (два вторых → каждому 60) — суммарная
--     выплата слегка растёт, но это честнее, чем решать судьбу награды порядком строк.
--   * Награда только местам 1–3 С НЕНУЛЕВЫМИ очками: иначе при <3 учениках с очками
--     в топ-3 попали бы ученики с 0 очков (все нули делят одно место по rank()).
--   * В архив пишутся ВСЕ ученики, включая нулевые очки («текущие очки всех учеников
--     записываются в архив», карточка G8) — при десятках учеников это дёшево.
--   * Следующий сезон открывается сразу же, той же транзакцией (start_date = сегодня
--     МСК) — иначе его границей стала бы дата первого открытия лидерборда (ленивое
--     создание из G7, остаётся только как bootstrap самого первого сезона).
--   * Повторное нажатие: сезон, открытый СЕГОДНЯ, закрыть нельзя (исключение) —
--     это блокирует и двойной клик (новый сезон всегда открыт сегодняшним числом),
--     и случайное закрытие только что открытого сезона. Легитимный сезон живёт
--     2 недели, так что ограничение ничего реального не запрещает. В dev для
--     повторного теста закрытия можно вручную отодвинуть start_date назад.
--   * Блокировки: строка seasons берётся for update (два одновременных закрытия
--     сериализуются), строки students блокируются целиком до снимка очков — чтобы
--     add_season_points, сработавший во время закрытия, не потерялся между архивом
--     и обнулением. perform-блокировка отдельным запросом, потому что for update
--     нельзя совмещать с оконной функцией rank() в одном select.
--
-- Функция вызывается anon-ключом из teacher.html — та же открытость, что у всего
-- проекта (принятый риск, ROADMAP.md T10): не создаёт новой дыры сверх существующей.

create or replace function public.close_season()
 returns json
 language plpgsql
as $function$
declare
  v_season_id bigint;
  v_start_date date;
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_archived integer;
  v_awarded integer := 0;
  v_reward integer;
  r record;
begin
  select id, start_date into v_season_id, v_start_date
    from seasons
    where end_date is null
    order by id desc
    limit 1
    for update;

  if v_season_id is null then
    raise exception 'Нет открытого сезона';
  end if;

  if v_start_date >= v_today then
    raise exception 'Сезон №% открыт сегодня — закрывать можно не раньше следующего дня', v_season_id;
  end if;

  -- Блокируем учеников до снимка очков (см. шапку: гонка с add_season_points).
  perform 1 from students for update;

  insert into season_results (season_id, student_id, points, place)
  select v_season_id, s.telegram_id, s.rating,
         rank() over (order by s.rating desc)
    from students s;
  get diagnostics v_archived = row_count;

  for r in
    select student_id, place
      from season_results
      where season_id = v_season_id and place <= 3 and points > 0
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;

  update students set rating = 0 where rating <> 0;

  update seasons set end_date = v_today where id = v_season_id;

  insert into seasons (start_date) values (v_today);

  return json_build_object(
    'season_id', v_season_id,
    'archived', v_archived,
    'awarded', v_awarded
  );
end;
$function$;
