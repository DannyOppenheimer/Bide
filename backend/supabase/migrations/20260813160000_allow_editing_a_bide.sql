-- Allow replanning without deleting participant state or ETA history. Any member
-- may edit a shared bide; only its creator may edit a solo bide. Column-level
-- grants limit changes to destination and schedule fields. Coordinates continue
-- to describe the shared destination, never a participant's location.

grant update (destination_name, lat, lng, scheduled_for) on public.bides to authenticated;

create policy "edit a bide you are part of"
  on public.bides for update to authenticated
  using (
    case
      when is_solo then created_by = (select auth.uid())
      else public.is_bide_participant(id)
    end
  )
  with check (
    case
      when is_solo then created_by = (select auth.uid())
      else public.is_bide_participant(id)
    end
  );

comment on policy "edit a bide you are part of" on public.bides is
  'Shared bides are editable by any participant; solo bides only by their creator. The column grant decides what may change.';
