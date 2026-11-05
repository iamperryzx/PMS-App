-- Run this file once in Supabase Dashboard > SQL Editor.
-- It creates the shared PMS schema with row-level security and a one-time owner code.
-- Copy the final query result and keep it private until the first owner account is activated.
-- Then run supabase-username-migration.sql to enable username/password staff accounts.
-- In Authentication > Sign In / Providers > Email, either disable Confirm email
-- or verify the first owner's email before logging in to claim the setup code.
create table if not exists public.pms_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    email text not null,
    full_name text not null,
    role text not null check (role in ('owner', 'staff')),
    active boolean not null default true,
    created_at timestamptz not null default now()
);

create table if not exists public.pms_branches (
    id uuid primary key default gen_random_uuid(),
    name text not null check (length(trim(name)) between 1 and 120),
    created_at timestamptz not null default now()
);

create table if not exists public.pms_branch_members (
    branch_id uuid not null references public.pms_branches(id) on delete cascade,
    user_id uuid not null references public.pms_profiles(user_id) on delete cascade,
    active boolean not null default true,
    created_at timestamptz not null default now(),
    primary key (branch_id, user_id)
);

create table if not exists public.pms_branch_data (
    branch_id uuid primary key references public.pms_branches(id) on delete cascade,
    state jsonb not null default '{"rooms":[],"inventory":[],"invoices":[],"transactions":[],"categories":[],"hotelInfo":{}}'::jsonb,
    revision bigint not null default 0,
    updated_at timestamptz not null default now()
);

create table if not exists public.pms_staff_invites (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null references public.pms_branches(id) on delete cascade,
    email text not null,
    full_name text not null,
    code text not null unique,
    created_by uuid not null references public.pms_profiles(user_id),
    used_at timestamptz,
    created_at timestamptz not null default now()
);

create table if not exists public.pms_project_installation (
    id boolean primary key default true check (id),
    bootstrap_code text not null,
    owner_claimed boolean not null default false
);

alter table public.pms_profiles enable row level security;
alter table public.pms_branches enable row level security;
alter table public.pms_branch_members enable row level security;
alter table public.pms_branch_data enable row level security;
alter table public.pms_staff_invites enable row level security;
alter table public.pms_project_installation enable row level security;

revoke all on public.pms_profiles, public.pms_branches, public.pms_branch_members,
    public.pms_branch_data, public.pms_staff_invites, public.pms_project_installation
from public, anon, authenticated;

create or replace function public.pms_claim_owner(p_code text, p_full_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_email text := lower(auth.jwt() ->> 'email');
begin
    if v_user_id is null or v_email is null or length(trim(p_full_name)) = 0 then
        raise exception 'A valid signed-in account and full name are required.';
    end if;

    perform 1 from public.pms_project_installation where id = true for update;
    if not found then
        raise exception 'Run supabase-setup.sql in the Supabase SQL Editor first.';
    end if;
    if exists (select 1 from public.pms_profiles where role = 'owner') then
        raise exception 'The project owner has already been set up.';
    end if;
    if not exists (
        select 1 from public.pms_project_installation
        where id = true and not owner_claimed and bootstrap_code = p_code
    ) then
        raise exception 'The setup code is invalid or has already been used.';
    end if;

    insert into public.pms_profiles (user_id, email, full_name, role)
    values (v_user_id, v_email, trim(p_full_name), 'owner');
    update public.pms_project_installation
    set owner_claimed = true, bootstrap_code = ''
    where id = true;

    return jsonb_build_object('role', 'owner', 'full_name', trim(p_full_name), 'email', v_email);
end;
$$;

create or replace function public.pms_get_account()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_profile public.pms_profiles%rowtype;
begin
    select * into v_profile
    from public.pms_profiles
    where user_id = auth.uid() and active;
    if not found then
        raise exception 'This account has not been activated for PMS.';
    end if;
    return jsonb_build_object(
        'email', v_profile.email,
        'full_name', v_profile.full_name,
        'role', v_profile.role
    );
end;
$$;

create or replace function public.pms_list_branches()
returns jsonb
language sql
security definer
set search_path = ''
as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.created_at), '[]'::jsonb)
    from public.pms_branch_members m
    join public.pms_branches b on b.id = m.branch_id
    join public.pms_profiles p on p.user_id = m.user_id and p.active
    where m.user_id = auth.uid() and m.active;
$$;

create or replace function public.pms_create_branch(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_branch public.pms_branches%rowtype;
begin
    if not exists (select 1 from public.pms_profiles where user_id = auth.uid() and role = 'owner' and active) then
        raise exception 'Only an active owner can create a branch.';
    end if;
    if length(trim(p_name)) not between 1 and 120 then
        raise exception 'Branch name must contain 1 to 120 characters.';
    end if;
    insert into public.pms_branches (name) values (trim(p_name)) returning * into v_branch;
    insert into public.pms_branch_members (branch_id, user_id) values (v_branch.id, auth.uid());
    insert into public.pms_branch_data (branch_id) values (v_branch.id);
    return jsonb_build_object('id', v_branch.id, 'name', v_branch.name);
end;
$$;

create or replace function public.pms_rename_branch(p_branch_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if length(trim(p_name)) not between 1 and 120 then
        raise exception 'Branch name must contain 1 to 120 characters.';
    end if;
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can rename it.';
    end if;
    update public.pms_branches set name = trim(p_name) where id = p_branch_id;
    if not found then raise exception 'Branch not found.'; end if;
end;
$$;

create or replace function public.pms_delete_branch(p_branch_id uuid)
returns void
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
        raise exception 'Only an owner of this branch can delete it.';
    end if;
    delete from public.pms_branches where id = p_branch_id;
    if not found then raise exception 'Branch not found.'; end if;
end;
$$;

create or replace function public.pms_get_branch_data(p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_data public.pms_branch_data%rowtype;
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active
    ) then
        raise exception 'You do not have access to this branch.';
    end if;
    select * into v_data from public.pms_branch_data where branch_id = p_branch_id;
    if not found then raise exception 'Branch data not found.'; end if;
    return jsonb_build_object('state', v_data.state, 'revision', v_data.revision);
end;
$$;

create or replace function public.pms_save_branch_data(p_branch_id uuid, p_state jsonb, p_expected_revision bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_revision bigint;
    v_current_state jsonb;
    v_role text;
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active
    ) then
        raise exception 'You do not have access to this branch.';
    end if;
    select revision, state into v_revision, v_current_state
    from public.pms_branch_data
    where branch_id = p_branch_id
    for update;
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
    select role into v_role from public.pms_profiles where user_id = auth.uid() and active;
    if v_role = 'staff' then
        if p_state -> 'categories' is distinct from v_current_state -> 'categories'
            or p_state -> 'hotelInfo' is distinct from v_current_state -> 'hotelInfo'
            or p_state -> 'transactions' is distinct from v_current_state -> 'transactions' then
            raise exception 'Receptionist accounts cannot change hotel settings, room rates, or cash transactions.';
        end if;
        if (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', room.value -> 'id', 'name', room.value -> 'name', 'category', room.value -> 'category'
            ) order by room.value ->> 'id'), '[]'::jsonb)
            from jsonb_array_elements(v_current_state -> 'rooms') as room(value)
        ) is distinct from (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', room.value -> 'id', 'name', room.value -> 'name', 'category', room.value -> 'category'
            ) order by room.value ->> 'id'), '[]'::jsonb)
            from jsonb_array_elements(p_state -> 'rooms') as room(value)
        ) then
            raise exception 'Receptionist accounts cannot add, remove, or reconfigure rooms.';
        end if;
        if (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', item.value -> 'id', 'name', item.value -> 'name',
                'unit', item.value -> 'unit', 'price', item.value -> 'price'
            ) order by item.value ->> 'id'), '[]'::jsonb)
            from jsonb_array_elements(v_current_state -> 'inventory') as item(value)
        ) is distinct from (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', item.value -> 'id', 'name', item.value -> 'name',
                'unit', item.value -> 'unit', 'price', item.value -> 'price'
            ) order by item.value ->> 'id'), '[]'::jsonb)
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
            'email', p.email, 'fullName', p.full_name, 'active', m.active
        ) order by p.full_name), '[]'::jsonb)
        from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and p.role = 'staff'
    );
end;
$$;

create or replace function public.pms_create_staff_invite(p_branch_id uuid, p_email text, p_full_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_code text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    v_email text := lower(trim(p_email));
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can invite staff.';
    end if;
    if v_email = '' or length(trim(p_full_name)) = 0 then
        raise exception 'Email and full name are required.';
    end if;
    insert into public.pms_staff_invites (branch_id, email, full_name, code, created_by)
    values (p_branch_id, v_email, trim(p_full_name), v_code, auth.uid());
    return v_code;
end;
$$;

create or replace function public.pms_accept_staff_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_invite public.pms_staff_invites%rowtype;
    v_user_id uuid := auth.uid();
    v_email text := lower(auth.jwt() ->> 'email');
begin
    select * into v_invite
    from public.pms_staff_invites
    where code = p_code and email = v_email and used_at is null
    for update;
    if not found then raise exception 'Invitation is invalid, already used, or belongs to another email.'; end if;
    insert into public.pms_profiles (user_id, email, full_name, role)
    values (v_user_id, v_email, v_invite.full_name, 'staff')
    on conflict (user_id) do update
    set email = excluded.email, full_name = excluded.full_name, active = true;
    insert into public.pms_branch_members (branch_id, user_id)
    values (v_invite.branch_id, v_user_id)
    on conflict (branch_id, user_id) do update set active = true;
    update public.pms_staff_invites set used_at = now() where id = v_invite.id;
    return jsonb_build_object('role', 'staff', 'full_name', v_invite.full_name, 'email', v_email);
end;
$$;

create or replace function public.pms_set_staff_active(p_branch_id uuid, p_email text, p_active boolean)
returns void
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
    update public.pms_branch_members m
    set active = p_active
    from public.pms_profiles p
    where m.branch_id = p_branch_id and m.user_id = p.user_id
      and lower(p.email) = lower(trim(p_email)) and p.role = 'staff';
    if not found then raise exception 'Staff account not found.'; end if;
end;
$$;

revoke execute on function public.pms_claim_owner(text, text) from public, anon;
revoke execute on function public.pms_get_account() from public, anon;
revoke execute on function public.pms_list_branches() from public, anon;
revoke execute on function public.pms_create_branch(text) from public, anon;
revoke execute on function public.pms_rename_branch(uuid, text) from public, anon;
revoke execute on function public.pms_delete_branch(uuid) from public, anon;
revoke execute on function public.pms_get_branch_data(uuid) from public, anon;
revoke execute on function public.pms_save_branch_data(uuid, jsonb, bigint) from public, anon;
revoke execute on function public.pms_list_staff(uuid) from public, anon;
revoke execute on function public.pms_create_staff_invite(uuid, text, text) from public, anon;
revoke execute on function public.pms_accept_staff_invite(text) from public, anon;
revoke execute on function public.pms_set_staff_active(uuid, text, boolean) from public, anon;
grant execute on function public.pms_claim_owner(text, text) to authenticated;
grant execute on function public.pms_get_account() to authenticated;
grant execute on function public.pms_list_branches() to authenticated;
grant execute on function public.pms_create_branch(text) to authenticated;
grant execute on function public.pms_rename_branch(uuid, text) to authenticated;
grant execute on function public.pms_delete_branch(uuid) to authenticated;
grant execute on function public.pms_get_branch_data(uuid) to authenticated;
grant execute on function public.pms_save_branch_data(uuid, jsonb, bigint) to authenticated;
grant execute on function public.pms_list_staff(uuid) to authenticated;
grant execute on function public.pms_create_staff_invite(uuid, text, text) to authenticated;
grant execute on function public.pms_accept_staff_invite(text) to authenticated;
grant execute on function public.pms_set_staff_active(uuid, text, boolean) to authenticated;

insert into public.pms_project_installation (id, bootstrap_code)
values (true, 'OWNER-' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

select bootstrap_code as one_time_owner_setup_code
from public.pms_project_installation
where id = true and not owner_claimed;

notify pgrst, 'reload schema';
