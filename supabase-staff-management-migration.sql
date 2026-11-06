-- Run once in Supabase Dashboard > SQL Editor after supabase-username-migration.sql.
-- Adds owner-only staff account editing and branch-scoped account deletion.

create or replace function public.pms_update_staff_account(
    p_branch_id uuid,
    p_username text,
    p_new_username text,
    p_password text,
    p_full_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_old_username text;
    v_new_username text := coalesce(lower(trim(p_new_username)), '');
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can manage staff.';
    end if;
    if v_new_username !~ '^[a-z0-9._-]{3,32}$' then
        raise exception 'Username must be 3 to 32 characters: letters, numbers, dot, underscore, or hyphen.';
    end if;
    if p_password is not null and length(p_password) not between 8 and 128 then
        raise exception 'Password must be 8 to 128 characters.';
    end if;
    if p_full_name is null or length(trim(p_full_name)) not between 1 and 120 then
        raise exception 'Full name must contain 1 to 120 characters.';
    end if;

    select p.user_id, coalesce(p.username, p.email)
    into v_user_id, v_old_username
    from public.pms_profiles p
    join public.pms_branch_members m on m.user_id = p.user_id
    where m.branch_id = p_branch_id
      and lower(coalesce(p.username, p.email)) = lower(trim(p_username))
      and p.role = 'staff'
    for update of p;
    if not found then raise exception 'Staff account not found in this branch.'; end if;

    update public.pms_profiles
    set username = v_new_username,
        full_name = trim(p_full_name),
        password_hash = case
            when p_password is null or p_password = '' then password_hash
            else extensions.crypt(p_password, extensions.gen_salt('bf', 12))
        end
    where user_id = v_user_id;

    if lower(v_old_username) <> v_new_username or (p_password is not null and p_password <> '') then
        delete from public.pms_staff_sessions where user_id = v_user_id;
    end if;
    delete from public.pms_staff_login_attempts
    where lower(username) in (lower(v_old_username), v_new_username);
end;
$$;

create or replace function public.pms_delete_staff_account(
    p_branch_id uuid,
    p_username text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_username text;
begin
    if not exists (
        select 1 from public.pms_branch_members m
        join public.pms_profiles p on p.user_id = m.user_id
        where m.branch_id = p_branch_id and m.user_id = auth.uid()
          and m.active and p.active and p.role = 'owner'
    ) then
        raise exception 'Only an owner of this branch can manage staff.';
    end if;

    select p.user_id, coalesce(p.username, p.email)
    into v_user_id, v_username
    from public.pms_profiles p
    join public.pms_branch_members m on m.user_id = p.user_id
    where m.branch_id = p_branch_id
      and lower(coalesce(p.username, p.email)) = lower(trim(p_username))
      and p.role = 'staff'
    for update of p;
    if not found then raise exception 'Staff account not found in this branch.'; end if;

    delete from public.pms_branch_members
    where branch_id = p_branch_id and user_id = v_user_id;
    if not exists (
        select 1 from public.pms_branch_members where user_id = v_user_id
    ) then
        delete from public.pms_profiles where user_id = v_user_id;
    end if;
    delete from public.pms_staff_login_attempts where lower(username) = lower(v_username);
end;
$$;

revoke execute on function public.pms_update_staff_account(uuid, text, text, text, text) from public, anon;
revoke execute on function public.pms_delete_staff_account(uuid, text) from public, anon;
grant execute on function public.pms_update_staff_account(uuid, text, text, text, text) to authenticated;
grant execute on function public.pms_delete_staff_account(uuid, text) to authenticated;

notify pgrst, 'reload schema';
