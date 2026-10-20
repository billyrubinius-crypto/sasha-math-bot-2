"""Extract pure bot helpers via AST: no bot token, .env, imports or outgoing messages."""
import ast
from datetime import datetime, timedelta, timezone
from pathlib import Path

source = ast.parse((Path(__file__).resolve().parent.parent / 'main.py').read_text(encoding='utf-8'))
names = {'week_start_of', 'group_counts_by_student', 'is_effectively_active',
         'has_open_revision_window', 'classify_evening_row', 'group_evening_by_student'}
helpers = ast.Module(body=[n for n in source.body if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[])
ns = {'datetime': datetime, 'timedelta': timedelta}
exec(compile(helpers, 'main.py helpers', 'exec'), ns)
rows = [dict(student_id=1, type='weekly', week_label=week, scheduled_date=week,
             status='assigned', activation_status='scheduled')
        for week in ['2026-09-28', '2026-10-05', '2026-10-12', '2026-10-19', '2026-10-26']]
rows.append(dict(student_id=1, type='individual', status='assigned', activation_status='active'))
for today, week in [('2026-10-18', '2026-10-12'), ('2026-10-19', '2026-10-19')]:
    available = [r for r in rows if ns['is_effectively_active'](r, today)]
    assert ns['group_counts_by_student'](available, today) == {1: {'daily': 0, 'weekly': 1, 'individual': 1}}
    now = datetime.fromisoformat(today + 'T19:00:00+03:00')
    evening = ns['group_evening_by_student'](rows, today, week, now)
    assert evening[1]['new']['weekly'] == 1
assert ns['week_start_of'](datetime(2027, 1, 1).date()) == '2026-12-28'
print('PASS weekly bot counts: Sunday/Monday, past/future excluded, one current week, individual preserved.')
