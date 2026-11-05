-- Run once in Supabase SQL Editor after supabase-setup.sql.
-- Existing owner accounts and branches are preserved.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.pms_profiles
    drop constraint if exists pms_profiles_user_id_fkey;
alter table public.pms_profiles
    alter column email drop not null;
alter table public.pms_profiles
    add column if not exists username text,
    add column if not exists password_hash text;

create unique index if not exists pms_profiles_username_lower_key
    on public.pms_profiles (lower(username))
    where username is not null;

create table if not exists public.pms_staff_sessions (
    token_hash text primary key,
    user_id uuid not null references public.pms_profiles(user_id) on delete cascade,
    expires_at timestamptz not null,
    created_at timestamptz not null default now()
);

create table if not exists public.pms_staff_login_attempts (
    username text primary key,
    failed_count integer not null default 0,
    last_attempt_at timestamptz not null default now(),
    blocked_until timestamptz
);

alter table public.pms_staff_sessions enable row level security;
alter table public.pms_staff_login_attempts enable row level security;
revoke all on public.pms_staff_sessions, public.pms_staff_login_attempts
    from public, anon, authenticated;

drop function if exists public.pms_get_account();
drop function if exists public.pms_list_branches();
drop function if exists public.pms_get_branch_data(uuid);
drop function if exists public.pms_save_branch_data(uuid, jsonb, bigint);
drop function if exists public.pms_set_staff_active(uuid, text, boolean);
drop function if exists public.pms_create_staff_invite(uuid, text, text);
drop function if exists public.pms_accept_staff_invite(text);

create or replace function public.pms_resolve_user_id(p_staff_token text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
begin
    if auth.uid() is not null then
        select user_id into v_user_id
        from public.pms_profiles
        where user_id = auth.uid() and active;
        return v_user_id;
    end if;
    if p_staff_token is null or p_staff_token = '' then return null; end if;

    select s.user_id into v_user_id
    from public.pms_staff_sessions s
    join public.pms_profiles p on p.user_id = s.user_id and p.active and p.role = 'staff'
    join public.pms_branch_members m on m.user_id = s.user_id and m.active
    where s.token_hash = encode(extensions.digest(p_staff_token, 'sha256'), 'hex')
      and s.expires_at > now()
    limit 1;
    return v_user_id;
end;
$$;

create or replace function public.pms_get_account(p_staff_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := public.pms_resolve_user_id(p_staff_token);
    v_profile public.pms_profiles%rowtype;
begin
    if v_user_id is null then raise exception 'This account has not been activated for PMS.'; end if;
    select * into v_profile from public.pms_profiles where user_id = v_user_id and active;
    if not found then raise exception 'This account has not been activated for PMS.'; end if;
    return jsonb_build_object(
        'email', v_profile.email,
        'username', coalesce(v_profile.username, v_profile.email),
        'full_name', v_profile.full_name,
        'role', v_profile.role
    );
end;
$$;

create or replace function public.pms_list_branches(p_staff_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := public.pms_resolve_user_id(p_staff_token);
begin
    if v_user_id is null then raise exception 'This account has not been activated for PMS.'; end if;
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object('id', b.id, 'name', b.name) order by b.created_at
        ), '[]'::jsonb)
        from public.pms_branch_members m
        join public.pms_branches b on b.id = m.branch_id
        where m.user_id = v_user_id and m.active
    );
end;
$$;

create or replace function public.pms_get_branch_data(p_branch_id uuid, p_staff_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := public.pms_resolve_user_id(p_staff_token);
    v_data public.pms_branch_data%rowtype;
begin
    if v_user_id is null or not exists (
        select 1 from public.pms_branch_members
        where branch_id = p_branch_id and user_id = v_user_id and active
    ) then
        raise exception 'You do not have access to this branch.';
    end if;
    select * into v_data from public.pms_branch_data where branch_id = p_branch_id;
    if not found then raise exception 'Branch data not found.'; end if;
    return jsonb_build_object('state', v_data.state, 'revision', v_data.revision);
end;
$$;

create or replace function public.pms_save_branch_data(
    p_branch_id uuid,
    p_state jsonb,
    p_expected_revision bigint,
    p_staff_token text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := public.pms_resolve_user_id(p_staff_token);
    v_revision bigint;
    v_current_state jsonb;
    v_role text;
begin
    if v_user_id is null or not exists (
        select 1 from public.pms_branch_members
        where branch_id = p_branch_id and user_id = v_user_id and active
    ) then
        raise exception 'You do not have access to this branch.';
    end if;
    select revision, state into v_revision, v_current_state
    from public.pms_branch_data where branch_id = p_branch_id for update;
    if not found then raise exception 'Branch data not found.'; end if;
    if v_revision <> p_expected_revision then
        raise exception 'PMS_CONFLICT: data changed on another device.';
    end if;
    if jsonb_typeof(p_state) is distinct from 'object'
        or jsonb_typeof(p_state -> 'rooms') is distinct from 'array'
        or jsonb_typeof(p_state -> 'inventory') is distinct from 'array'
        or jsonb_typeof(p_state -> 'invoices') is distinct from 'array'
        or jsonb_typeof(p_state -> 'transactions') is distinct from 'array'
        or jsonb_typeof(p_state -> 'categories') is distinct from 'array'
        or jsonb_typeof(p_state -> 'hotelInfo') is distinct from 'object' then
        raise exception 'Invalid PMS data shape.';
    end if;

    select role into v_role from public.pms_profiles where user_id = v_user_id and active;
    if v_role = 'staff' then
        if (p_state - 'rooms' - 'inventory' - 'invoices')
            is distinct from (v_current_state - 'rooms' - 'inventory' - 'invoices') then
            raise exception 'Receptionist accounts cannot change hotel settings, room rates, or cash transactions.';
        end if;
        if (
            select coalesce(jsonb_agg(jsonb_build_object(
                'room', room.value - 'status' - 'guestInfo'
            ) order by (room.value - 'status' - 'guestInfo')::text), '[]'::jsonb)
            from jsonb_array_elements(v_current_state -> 'rooms') as room(value)
        ) is distinct from (
            select coalesce(jsonb_agg(jsonb_build_object(
                'room', room.value - 'status' - 'guestInfo'
            ) order by (room.value - 'status' - 'guestInfo')::text), '[]'::jsonb)
            from jsonb_array_elements(p_state -> 'rooms') as room(value)
        ) then
            raise exception 'Receptionist accounts cannot add, remove, or reconfigure rooms.';
        end if;
        if (
            select coalesce(jsonb_agg(jsonb_build_object(
                'item', item.value - 'stock'
            ) order by (item.value - 'stock')::text), '[]'::jsonb)
            from jsonb_array_elements(v_current_state -> 'inventory') as item(value)
        ) is distinct from (
            select coalesce(jsonb_agg(jsonb_build_object(
                'item', item.value - 'stock'
            ) order by (item.value - 'stock')::text), '[]'::jsonb)
            from jsonb_array_elements(p_state -> 'inventory') as item(value)
        ) then
            raise exception 'Receptionist accounts cannot add, remove, or reconfigure inventory items.';
        end if;
        if exists (
            select 1
            from jsonb_array_elements(v_current_state -> 'invoices') as old_invoice(value)
            where not exists (
                select 1
                from jsonb_array_elements(p_state -> 'invoices') as new_invoice(value)
                where new_invoice.value ->> 'id' = old_invoice.value ->> 'id'
                  and new_invoice.value = old_invoice.value
            )
        ) then
            raise exception 'Receptionist accounts cannot alter or delete existing invoices.';
        end if;
    elsif v_role <> 'owner' then
        raise exception 'This account cannot change PMS data.';
    end if;

    update public.pms_branch_data
    set state = p_state, revision = revision + 1, updated_at = now()
    where branch_id = p_branch_id
    returning revision into v_revision;
    return v_revision;
end;
$$;

create or replace function public.pms_staff_login(p_username text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_username text := coalesce(lower(trim(p_username)), '');
    v_profile public.pms_profiles%rowtype;
    v_branch_id uuid;
    v_blocked_until timestamptz;
    v_token text;
begin
    if v_username !~ '^[a-z0-9._-]{3,32}$' or p_password is null or length(p_password) > 128 then
        return jsonb_build_object('error', 'Tên đăng nhập hoặc mật khẩu không chính xác.');
    end if;
    select blocked_until into v_blocked_until
    from public.pms_staff_login_attempts where username = v_username for update;
    if v_blocked_until > now() then
        return jsonb_build_object('error', 'Tài khoản tạm khóa đăng nhập. Vui lòng thử lại sau 15 phút.');
    end if;

    select p.* into v_profile
    from public.pms_profiles p
    where lower(p.username) = v_username and p.role = 'staff' and p.active;
    if found and v_profile.password_hash is not null
        and extensions.crypt(p_password, v_profile.password_hash) = v_profile.password_hash then
        select m.branch_id into v_branch_id
        from public.pms_branch_members m
        where m.user_id = v_profile.user_id and m.active
        order by m.created_at
        limit 1;
        if v_branch_id is not null then
            v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
            insert into public.pms_staff_sessions (token_hash, user_id, expires_at)
            values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_profile.user_id, now() + interval '30 days');
            delete from public.pms_staff_login_attempts where username = v_username;
            return jsonb_build_object('staff_token', v_token);
        end if;
    end if;

    insert into public.pms_staff_login_attempts as attempts (username, failed_count, last_attempt_at, blocked_until)
    values (v_username, 1, now(), null)
    on conflict (username) do update set
        failed_count = case
            when attempts.last_attempt_at < now() - interval '15 minutes' then 1
            else attempts.failed_count + 1
        end,
        blocked_until = case
            when attempts.last_attempt_at < now() - interval '15 minutes' then null
            when attempts.failed_count + 1 >= 5 then now() + interval '15 minutes'
            else attempts.blocked_until
        end,
        last_attempt_at = now();
    return jsonb_build_object('error', 'Tên đăng nhập hoặc mật khẩu không chính xác.');
end;
$$;

create or replace function public.pms_staff_logout(p_staff_token text)
returns void
language sql
security definer
set search_path = ''
as $$
    delete from public.pms_staff_sessions
    where token_hash = encode(extensions.digest(p_staff_token, 'sha256'), 'hex');
$$;

create or replace function public.pms_create_staff_account(
    p_branch_id uuid,
    p_username text,
    p_password text,
    p_full_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_username text := coalesce(lower(trim(p_username)), '');
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can create staff accounts.';
    end if;
    if v_username !~ '^[a-z0-9._-]{3,32}$' then
        raise exception 'Username must be 3 to 32 characters: letters, numbers, dot, underscore, or hyphen.';
    end if;
    if p_password is null or length(p_password) < 8 or length(p_password) > 128 then
        raise exception 'Password must be 8 to 128 characters.';
    end if;
    if p_full_name is null or length(trim(p_full_name)) not between 1 and 120 then
        raise exception 'Full name must contain 1 to 120 characters.';
    end if;
    if exists (select 1 from public.pms_profiles where lower(username) = v_username) then
        raise exception 'That username is already in use.';
    end if;

    insert into public.pms_profiles (user_id, username, password_hash, full_name, role, active)
    values (
        gen_random_uuid(),
        v_username,
        extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
        trim(p_full_name),
        'staff',
        true
    );
    insert into public.pms_branch_members (branch_id, user_id)
    values (p_branch_id, (
        select user_id from public.pms_profiles where lower(username) = v_username
    ));
end;
$$;

create or replace function public.pms_list_staff(p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can manage staff.';
    end if;
    return (
        select coalesce(jsonb_agg(jsonb_build_object(
            'username', coalesce(p.username, p.email),
            'fullName', p.full_name,
            'active', m.active and p.active
        ) order by p.full_name), '[]'::jsonb)
        from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and p.role = 'staff'
    );
end;
$$;

create or replace function public.pms_set_staff_active(p_branch_id uuid, p_username text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can manage staff.';
    end if;
    select p.user_id into v_user_id
    from public.pms_profiles p
    join public.pms_branch_members m on m.user_id = p.user_id
    where m.branch_id = p_branch_id
      and lower(coalesce(p.username, p.email)) = lower(trim(p_username))
      and p.role = 'staff';
    if not found then raise exception 'Staff account not found in this branch.'; end if;
    update public.pms_branch_members set active = p_active
    where branch_id = p_branch_id and user_id = v_user_id;
    if not p_active then
        delete from public.pms_staff_sessions where user_id = v_user_id;
    end if;
end;
$$;

revoke execute on function public.pms_resolve_user_id(text) from public, anon;
revoke execute on function public.pms_get_account(text) from public, anon;
revoke execute on function public.pms_list_branches(text) from public, anon;
revoke execute on function public.pms_get_branch_data(uuid, text) from public, anon;
revoke execute on function public.pms_save_branch_data(uuid, jsonb, bigint, text) from public, anon;
revoke execute on function public.pms_staff_login(text, text) from public, anon;
revoke execute on function public.pms_staff_logout(text) from public, anon;
revoke execute on function public.pms_create_staff_account(uuid, text, text, text) from public, anon;
revoke execute on function public.pms_list_staff(uuid) from public, anon;
revoke execute on function public.pms_set_staff_active(uuid, text, boolean) from public, anon;

grant execute on function public.pms_get_account(text) to anon, authenticated;
grant execute on function public.pms_list_branches(text) to anon, authenticated;
grant execute on function public.pms_get_branch_data(uuid, text) to anon, authenticated;
grant execute on function public.pms_save_branch_data(uuid, jsonb, bigint, text) to anon, authenticated;
grant execute on function public.pms_staff_login(text, text) to anon, authenticated;
grant execute on function public.pms_staff_logout(text) to anon, authenticated;
grant execute on function public.pms_create_staff_account(uuid, text, text, text) to authenticated;
grant execute on function public.pms_list_staff(uuid) to authenticated;
grant execute on function public.pms_set_staff_active(uuid, text, boolean) to authenticated;

notify pgrst, 'reload schema';
