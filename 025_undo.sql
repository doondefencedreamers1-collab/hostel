-- =====================================================================
-- 025_undo.sql — 025 wapas: sirf ddd_find_similar_students function drop.
-- Koi data row nahi badalti. Safe to run twice.
-- App iske bina bhi chalti hai: Add Student par doosre hostel ka check
-- chup-chaap skip hota hai, apne hostel ka duplicate check chalta rehta hai.
-- =====================================================================
begin;

drop function if exists public.ddd_find_similar_students(text, text, text[], text);

commit;

notify pgrst, 'reload schema';

-- check (0 aana chahiye):
-- select count(*) from pg_proc where proname = 'ddd_find_similar_students';
