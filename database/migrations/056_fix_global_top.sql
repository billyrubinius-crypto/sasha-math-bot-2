begin;

-- The TABLE return columns are PL/pgSQL variables. The original aggregation used an
-- unqualified student_id, so PostgreSQL raised 42702 at runtime instead of returning rows.
-- Keep the function signature and grants stable; qualify every season_results reference.
create or replace function public.get_global_top_self(
  p_limit  integer default 100,
  p_offset integer default 0)
 returns table(
   place           integer,
   student_id      bigint,
   name            text,
   lifetime_points integer,
   season_points   integer,
   equipment       jsonb,
   total_students  integer)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_limit  integer;
  v_offset integer;
begin
  if private.current_app_role() not in ('student', 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_limit  := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  with totals as (
    select s.telegram_id as student_id,
           coalesce(s.name, '') as name,
           coalesce(s.rating, 0) as season_points,
           coalesce(a.total, 0) + coalesce(s.rating, 0) as lifetime_points
      from public.students s
      left join (
        select sr.student_id, sum(sr.points)::integer as total
          from public.season_results sr
         group by sr.student_id
      ) a on a.student_id = s.telegram_id
  ),
  ranked as (
    select t.*,
           (row_number() over (
              order by t.lifetime_points desc,
                       t.season_points desc,
                       t.name asc,
                       t.student_id asc))::integer as place,
           (count(*) over ())::integer as total_students
      from totals t
  )
  select r.place,
         r.student_id,
         r.name,
         r.lifetime_points,
         r.season_points,
         public.student_public_cosmetics(r.student_id),
         r.total_students
    from ranked r
   order by r.place
   limit v_limit offset v_offset;
end;
$function$;

revoke all on function public.get_global_top_self(integer, integer) from public, anon;
grant execute on function public.get_global_top_self(integer, integer) to authenticated;

commit;
