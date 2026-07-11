-- Миграция 001 — RPC для атомарного начисления/списания хуиконов (ROADMAP.md, задача T5)
--
-- Зачем: сейчас баланс обновляется по схеме "прочитал -> прибавил в JS -> записал" в 4 местах
-- (index.html: uploadDZ(); teacher.html: processStreak(), awardApprovalBonus(), applyPenalty()).
-- При параллельных операциях над одним учеником одно из начислений может потеряться (последняя
-- запись выигрывает). Эта функция делает "прочитать -> посчитать -> записать" одной атомарной
-- операцией на стороне Postgres (SELECT ... FOR UPDATE блокирует строку на время транзакции,
-- PostgREST выполняет каждый RPC-вызов в отдельной транзакции — конкурентные вызовы для одного
-- и того же student_id сериализуются автоматически).
--
-- Дополнительно: возвращает и фактически применённое изменение, и новый баланс — это устраняет
-- баг А11 (штраф записывал в историю не фактически списанную сумму, если баланс клампился нулём)
-- по конструкции, а не отдельной правкой на клиенте.

create or replace function public.add_huikons(p_student_id bigint, p_amount int, p_reason text)
returns table(actual_change int, new_balance int)
language plpgsql
as $$
declare
  v_old_balance int;
  v_new_balance int;
begin
  select huikons into v_old_balance
    from students
    where telegram_id = p_student_id
    for update;

  if v_old_balance is null then
    raise exception 'Student % not found', p_student_id;
  end if;

  v_new_balance := greatest(0, v_old_balance + p_amount);

  update students set huikons = v_new_balance where telegram_id = p_student_id;

  insert into balance_history (student_id, change_amount, reason)
    values (p_student_id, v_new_balance - v_old_balance, p_reason);

  return query select (v_new_balance - v_old_balance), v_new_balance;
end;
$$;
