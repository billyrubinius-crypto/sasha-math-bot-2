-- =============================================================================
-- b2_stabilize_seasons_rating.sql — стабилизационный этап, задачи 1 и 3.
-- Общий (накопительный) рейтинг + планирование и активация сезонов.
-- Выполняется владельцем БД после миграций 051–053. Все synthetic-данные откатываются
-- (транзакция завершается ROLLBACK), боевые строки не изменяются.
--
-- Покрывает обязательные сценарии отчёта:
--   ОБЩИЙ РЕЙТИНГ
--     1. два завершённых сезона суммируются;
--     2. сброс текущего рейтинга не уменьшает общий;
--     3. повторное завершение сезона не увеличивает итог второй раз;
--     4. в глобальном топе есть ученик, не участвующий в текущей лиге;
--     5. в глобальном топе присутствуют все допустимые зарегистрированные ученики.
--   СЕЗОНЫ
--     1. учитель создаёт будущий сезон;
--     2. нельзя создать сезон с окончанием раньше начала;
--     3. нельзя создать дублирующийся номер;
--     4. нельзя создать конфликтующий активный период;
--     5. ученик не может создать сезон напрямую;
--     6. при наступлении даты статус определяется корректно;
--     7. завершение происходит один раз.
-- =============================================================================

begin;

do $test$
declare
  v_a        bigint := 995051001;   -- ученик, набирающий очки во всех сезонах
  v_b        bigint := 995051002;   -- ученик, который в текущем сезоне не играет
  v_c        bigint := 995051003;   -- пустой аккаунт (0 очков за всю историю)
  v_season1  bigint;
  v_season2  bigint;
  v_season3  bigint;
  v_planned  bigint;
  v_res      json;
  v_res2     json;
  v_lifetime integer;
  v_cnt      integer;
  v_failed   text;
  v_top      record;
begin
  -- --- Подготовка: три synthetic-ученика --------------------------------------------------
  insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_a, 'STAB-A synthetic', 'stab_a', 0, 0, 3, 0),
         (v_b, 'STAB-B synthetic', 'stab_b', 0, 0, 3, 0),
         (v_c, 'STAB-C synthetic', 'stab_c', 0, 0, 3, 0);

  -- Текущий сезон: берём фактический активный, а если его нет — открываем.
  v_season1 := public.current_season_id();
  if v_season1 is null then
    v_season1 := public.start_next_season(true);
  end if;
  -- Сезон, открытый сегодня, close_season закрывать не даёт (защита от двойного клика);
  -- для теста сдвигаем дату старта в прошлое.
  update public.seasons set start_date = (now() at time zone 'Europe/Moscow')::date - 30
   where id = v_season1;

  -- =========================================================================================
  -- ОБЩИЙ РЕЙТИНГ 1: два завершённых сезона суммируются (120 + 80 = 200).
  -- =========================================================================================
  perform public.award_season_points(v_a, 120, 'test_season1', 'stab_s1_' || v_a);
  perform public.award_season_points(v_b, 55,  'test_season1', 'stab_s1_' || v_b);

  if (select rating from public.students where telegram_id = v_a) <> 120 then
    raise exception 'FAIL: сезонный рейтинг сезона 1 не 120';
  end if;

  v_res := public.finish_season(v_season1);
  v_season2 := (v_res->>'next_season_id')::bigint;
  if v_season2 is null then
    raise exception 'FAIL: следующий сезон не открыт при завершении';
  end if;

  -- ОБЩИЙ РЕЙТИНГ 2: сброс сезонного рейтинга не уменьшает общий.
  if (select rating from public.students where telegram_id = v_a) <> 0 then
    raise exception 'FAIL: сезонный рейтинг не обнулён при закрытии сезона';
  end if;
  v_lifetime := public.student_lifetime_points(v_a);
  if v_lifetime <> 120 then
    raise exception 'FAIL: общий рейтинг после сброса = % (ожидалось 120)', v_lifetime;
  end if;

  -- ОБЩИЙ РЕЙТИНГ 3: повторное завершение того же сезона — no-op, итог не удваивается.
  v_res2 := public.finish_season(v_season1);
  if (v_res2->>'already_completed')::boolean is not true then
    raise exception 'FAIL: повторное завершение сезона не распознано как already_completed';
  end if;
  if (select count(*) from public.season_results
       where season_id = v_season1 and student_id = v_a) <> 1 then
    raise exception 'FAIL: повторное завершение создало второй итог сезона';
  end if;
  if public.student_lifetime_points(v_a) <> 120 then
    raise exception 'FAIL: повторное завершение изменило общий рейтинг';
  end if;
  if (select count(*) from public.balance_history
       where student_id = v_a and reason like 'season_place_%') > 1 then
    raise exception 'FAIL: приз за место выплачен дважды';
  end if;

  -- Второй сезон: A набирает ещё 80, B не играет вовсе.
  update public.seasons set start_date = (now() at time zone 'Europe/Moscow')::date - 15
   where id = v_season2;
  perform public.award_season_points(v_a, 80, 'test_season2', 'stab_s2_' || v_a);

  v_res := public.finish_season(v_season2);
  v_season3 := (v_res->>'next_season_id')::bigint;

  v_lifetime := public.student_lifetime_points(v_a);
  if v_lifetime <> 200 then
    raise exception 'FAIL: два сезона (120 + 80) дали общий рейтинг % вместо 200', v_lifetime;
  end if;

  -- Текущий сезон добавляется к архиву: 200 + 15 = 215.
  perform public.award_season_points(v_a, 15, 'test_season3', 'stab_s3_' || v_a);
  if public.student_lifetime_points(v_a) <> 215 then
    raise exception 'FAIL: очки текущего сезона не прибавляются к общему рейтингу';
  end if;

  -- =========================================================================================
  -- ОБЩИЙ РЕЙТИНГ 4 и 5: выдача глобального топа.
  -- =========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('app_role', 'student', 'telegram_id', v_a::text)::text, true);

  select count(*) into v_cnt from public.get_global_top_self(500, 0);
  if v_cnt <> (select count(*) from public.students) then
    raise exception 'FAIL: в глобальном топе % строк, а учеников % — топ должен включать всех',
      v_cnt, (select count(*) from public.students);
  end if;

  -- B в текущем сезоне очков не набирал и в лиге текущего сезона не участвует, но в общем
  -- топе обязан присутствовать со своим историческим результатом.
  if exists (select 1 from public.league_memberships
              where season_id = v_season3 and student_id = v_b and activated_at is not null) then
    raise exception 'FAIL: подготовка теста неверна — B не должен быть в лиге текущего сезона';
  end if;
  select * into v_top from public.get_global_top_self(500, 0) t where t.student_id = v_b;
  if not found then
    raise exception 'FAIL: ученик вне текущей лиги отсутствует в глобальном топе';
  end if;
  if v_top.lifetime_points <> 55 then
    raise exception 'FAIL: общий рейтинг B = % вместо 55', v_top.lifetime_points;
  end if;

  -- Пустой аккаунт присутствует с нулём (он «зарегистрированный», а не «удалённый»).
  select * into v_top from public.get_global_top_self(500, 0) t where t.student_id = v_c;
  if not found then
    raise exception 'FAIL: пустой аккаунт отсутствует в глобальном топе';
  end if;
  if v_top.lifetime_points <> 0 then
    raise exception 'FAIL: общий рейтинг пустого аккаунта = % вместо 0', v_top.lifetime_points;
  end if;

  -- Пагинация не теряет строк: сумма страниц = total_students.
  select count(*) into v_cnt from (
    select student_id from public.get_global_top_self(2, 0)
    union all
    select student_id from public.get_global_top_self(500, 2)
  ) q;
  if v_cnt <> (select count(*) from public.students) then
    raise exception 'FAIL: страницы глобального топа теряют или дублируют строки (% из %)',
      v_cnt, (select count(*) from public.students);
  end if;

  -- A выше B: общий рейтинг 215 против 55.
  if (select place from public.get_global_top_self(500, 0) where student_id = v_a)
     >= (select place from public.get_global_top_self(500, 0) where student_id = v_b) then
    raise exception 'FAIL: сортировка глобального топа не по общему рейтингу';
  end if;

  -- =========================================================================================
  -- СЕЗОНЫ 5: ученик не может создать сезон напрямую.
  -- =========================================================================================
  v_failed := null;
  begin
    perform public.admin_create_season_self(999001, 'Хакерский сезон',
      now() + interval '10 days', now() + interval '24 days');
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null or position('forbidden' in v_failed) = 0 then
    raise exception 'FAIL: ученик смог вызвать admin_create_season_self (ошибка: %)', coalesce(v_failed, 'нет');
  end if;

  -- Дальше — от лица учителя.
  perform set_config('request.jwt.claims',
    json_build_object('app_role', 'teacher', 'teacher_id', 'stab-test',
                      'sub', '00000000-0000-0000-0000-0000000000aa')::text, true);

  -- СЕЗОНЫ 2: окончание раньше начала.
  v_failed := null;
  begin
    perform public.admin_create_season_self(999001, 'Плохое окно',
      now() + interval '20 days', now() + interval '10 days');
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null or position('window_order' in v_failed) = 0 then
    raise exception 'FAIL: сезон с окончанием раньше начала создался (%)', coalesce(v_failed, 'нет ошибки');
  end if;

  -- СЕЗОНЫ 3: дублирующийся номер.
  v_failed := null;
  begin
    perform public.admin_create_season_self(v_season3, 'Дубликат номера',
      now() + interval '10 days', now() + interval '24 days');
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null
     or (position('season_number_taken' in v_failed) = 0
         and position('season_number_too_small' in v_failed) = 0) then
    raise exception 'FAIL: сезон с существующим номером создался (%)', coalesce(v_failed, 'нет ошибки');
  end if;

  -- СЕЗОНЫ 1: учитель создаёт будущий сезон.
  v_planned := (select max(id) from public.seasons) + 1;
  perform public.admin_create_season_self(v_planned, 'Плановый сезон стабилизации',
    now() + interval '10 days', now() + interval '24 days');

  if (select status from public.seasons where id = v_planned) <> 'planned' then
    raise exception 'FAIL: созданный сезон не получил статус planned';
  end if;
  -- Инвариант совместимости: активным считается только сезон с end_date is null.
  if (select end_date from public.seasons where id = v_planned) is null then
    raise exception 'FAIL: у запланированного сезона end_date пуст — он подменит текущий во всех селекторах';
  end if;
  if (select count(*) from public.seasons where status = 'active') <> 1 then
    raise exception 'FAIL: активных сезонов не ровно один';
  end if;
  if public.current_season_id() <> v_season3 then
    raise exception 'FAIL: плановый сезон стал текущим до своей даты начала';
  end if;

  -- СЕЗОНЫ 4: конфликтующий период.
  v_failed := null;
  begin
    perform public.admin_create_season_self(v_planned + 1, 'Пересекающийся сезон',
      now() + interval '15 days', now() + interval '30 days');
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null or position('season_overlap' in v_failed) = 0 then
    raise exception 'FAIL: пересекающийся сезон создался (%)', coalesce(v_failed, 'нет ошибки');
  end if;

  -- Сезон в прошлом планировать нельзя.
  v_failed := null;
  begin
    perform public.admin_create_season_self(v_planned + 1, 'Сезон в прошлом',
      now() - interval '2 days', now() + interval '2 days');
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null then
    raise exception 'FAIL: сезон с началом в прошлом создался';
  end if;

  -- =========================================================================================
  -- СЕЗОНЫ 6 и 7: наступление даты + однократное завершение.
  -- =========================================================================================
  -- Сдвигаем плановое окно в прошлое (эмуляция «дата наступила»). Текущему сезону тоже
  -- проставляем истёкшее ends_at, чтобы сработал плановый переход.
  update public.seasons
     set starts_at = now() - interval '1 minute',
         ends_at   = now() + interval '13 days',
         start_date = (now() at time zone 'Europe/Moscow')::date,
         end_date   = ((now() + interval '13 days') at time zone 'Europe/Moscow')::date
   where id = v_planned;
  update public.seasons
     set ends_at = now() - interval '2 minutes',
         start_date = (now() at time zone 'Europe/Moscow')::date - 14
   where id = v_season3;

  perform public.ensure_season_schedule();

  if public.current_season_id() <> v_planned then
    raise exception 'FAIL: запланированный сезон не стал текущим после наступления даты (текущий %)',
      public.current_season_id();
  end if;
  if (select status from public.seasons where id = v_season3) <> 'completed' then
    raise exception 'FAIL: сезон с истёкшим ends_at не завершён';
  end if;
  if (select count(*) from public.seasons where status = 'active') <> 1 then
    raise exception 'FAIL: после планового перехода активных сезонов не ровно один';
  end if;

  -- Общий рейтинг пережил плановый переход: 200 архивных + 15 из завершённого сезона.
  if public.student_lifetime_points(v_a) <> 215 then
    raise exception 'FAIL: плановое завершение потеряло общий рейтинг (%)',
      public.student_lifetime_points(v_a);
  end if;

  -- СЕЗОНЫ 7: повторные «открытия приложения» второй раз сезон не завершают.
  select count(*) into v_cnt from public.season_results where season_id = v_season3;
  perform public.ensure_season_schedule();
  perform public.ensure_season_schedule();
  if (select count(*) from public.season_results where season_id = v_season3) <> v_cnt then
    raise exception 'FAIL: повторный ensure_season_schedule дописал итоги завершённого сезона';
  end if;
  if public.current_season_id() <> v_planned then
    raise exception 'FAIL: повторный ensure_season_schedule сменил текущий сезон';
  end if;

  raise notice 'PASS b2_stabilize_seasons_rating: lifetime rating, idempotent close, scheduled seasons';
end
$test$;

select 'PASS b2_stabilize_seasons_rating; transaction will be rolled back' as summary;

rollback;
