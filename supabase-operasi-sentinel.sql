-- =========================================================
-- OPERASI SENTINEL · undian nomor agen
-- Tempel seluruh isi file ini di Supabase → SQL Editor → Run
-- =========================================================

-- 1) Tabel operasi (satu baris per kode operasi)
create table if not exists public.operasi (
  code        text primary key,
  n           int  not null check (n between 12 and 200),
  admin_hash  text not null,
  dibuka      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- 2) Tabel klaim nomor (satu baris per nomor yang sudah diambil)
create table if not exists public.klaim (
  code        text not null references public.operasi(code) on delete cascade,
  num         int  not null,
  device      text not null,
  claimed_at  timestamptz not null default now(),
  primary key (code, num),
  unique (code, device)
);

-- 3) Kunci tabel: tidak ada akses langsung dari aplikasi.
--    Aplikasi hanya boleh memanggil fungsi-fungsi di bawah.
alter table public.operasi enable row level security;
alter table public.klaim   enable row level security;
revoke all on public.operasi, public.klaim from anon, authenticated;

-- 4) Fasilitator membuka operasi
create or replace function public.buka_operasi(p_code text, p_n int, p_admin text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_hash text := md5(p_admin || ':' || upper(p_code));
begin
  insert into operasi(code, n, admin_hash) values (upper(p_code), p_n, v_hash)
  on conflict (code) do nothing;
  return exists(select 1 from operasi where code = upper(p_code) and admin_hash = v_hash);
end $$;

-- 5) Peserta mengundi nomor (sekali per HP; menekan ulang memberi nomor yang sama)
create or replace function public.undi_nomor(p_code text, p_device text)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int; v_open boolean; v_num int;
begin
  select n, dibuka into v_n, v_open from operasi where code = upper(p_code) for update;
  if v_n is null then raise exception 'OPERASI_TIDAK_ADA'; end if;

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

-- 6) Fasilitator melihat progres undian
create or replace function public.status_undian(p_code text, p_admin text)
returns json language plpgsql security definer set search_path = public as $$
declare v operasi%rowtype;
begin
  select * into v from operasi where code = upper(p_code);
  if v.code is null or v.admin_hash <> md5(p_admin || ':' || upper(p_code)) then
    raise exception 'AKSES_DITOLAK';
  end if;
  return json_build_object(
    'n', v.n, 'dibuka', v.dibuka,
    'diambil', (select coalesce(json_agg(num order by num), '[]'::json) from klaim where code = v.code));
end $$;

-- 7) Fasilitator melepas satu nomor (mis. HP peserta mati) atau menutup/membuka undian
create or replace function public.lepas_nomor(p_code text, p_admin text, p_num int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from operasi where code = upper(p_code) and admin_hash = md5(p_admin || ':' || upper(p_code))) then
    raise exception 'AKSES_DITOLAK';
  end if;
  delete from klaim where code = upper(p_code) and num = p_num;
  return found;
end $$;

create or replace function public.atur_undian(p_code text, p_admin text, p_dibuka boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update operasi set dibuka = p_dibuka
  where code = upper(p_code) and admin_hash = md5(p_admin || ':' || upper(p_code));
  if not found then raise exception 'AKSES_DITOLAK'; end if;
  return p_dibuka;
end $$;

-- 8) Izinkan aplikasi memanggil fungsi-fungsi di atas
grant execute on function public.buka_operasi(text, int, text)       to anon;
grant execute on function public.undi_nomor(text, text)              to anon;
grant execute on function public.status_undian(text, text)           to anon;
grant execute on function public.lepas_nomor(text, text, int)        to anon;
grant execute on function public.atur_undian(text, text, boolean)    to anon;
