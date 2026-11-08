-- =========================================================
-- OPERASI SENTINEL · tambahan: akhiri permainan
-- Tempel seluruh isi file ini di Supabase → SQL Editor → Run
-- (aman dijalankan lebih dari sekali)
-- =========================================================

alter table public.operasi add column if not exists selesai boolean not null default false;

-- Fasilitator mengakhiri operasi: undian ditutup, semua peserta keluar otomatis
create or replace function public.akhiri_operasi(p_code text, p_admin text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update operasi set selesai = true, dibuka = false
  where code = upper(p_code) and admin_hash = md5(p_admin || ':' || upper(p_code));
  if not found then raise exception 'AKSES_DITOLAK'; end if;
  return true;
end $$;

-- HP peserta mengecek apakah operasinya sudah diakhiri
create or replace function public.cek_operasi(p_code text)
returns json language sql security definer set search_path = public as $$
  select json_build_object('ada', count(*) > 0, 'selesai', coalesce(bool_or(selesai), false))
  from operasi where code = upper(p_code);
$$;

-- Undian ditolak untuk operasi yang sudah selesai
create or replace function public.undi_nomor(p_code text, p_device text)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int; v_open boolean; v_done boolean; v_num int;
begin
  select n, dibuka, selesai into v_n, v_open, v_done from operasi where code = upper(p_code) for update;
  if v_n is null then raise exception 'OPERASI_TIDAK_ADA'; end if;
  if v_done then raise exception 'OPERASI_SELESAI'; end if;

  select num into v_num from klaim where code = upper(p_code) and device = p_device;
  if v_num is not null then return v_num; end if;

  if not v_open then raise exception 'UNDIAN_DITUTUP'; end if;

  select g into v_num
  from generate_series(1, v_n) g
  where not exists (select 1 from klaim k where k.code = upper(p_code) and k.num = g)
  order by random() limit 1;

  if v_num is null then raise exception 'NOMOR_HABIS'; end if;

  insert into klaim(code, num, device) values (upper(p_code), v_num, p_device);
  return v_num;
end $$;

-- Status undian ikut melaporkan apakah operasi sudah selesai
create or replace function public.status_undian(p_code text, p_admin text)
returns json language plpgsql security definer set search_path = public as $$
declare v operasi%rowtype;
begin
  select * into v from operasi where code = upper(p_code);
  if v.code is null or v.admin_hash <> md5(p_admin || ':' || upper(p_code)) then
    raise exception 'AKSES_DITOLAK';
  end if;
  return json_build_object(
    'n', v.n, 'dibuka', v.dibuka, 'selesai', v.selesai,
    'diambil', (select coalesce(json_agg(num order by num), '[]'::json) from klaim where code = v.code));
end $$;

grant execute on function public.akhiri_operasi(text, text) to anon;
grant execute on function public.cek_operasi(text)          to anon;
grant execute on function public.undi_nomor(text, text)     to anon;
grant execute on function public.status_undian(text, text)  to anon;
