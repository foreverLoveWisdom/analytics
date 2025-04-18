defmodule Plausible.Repo.Migrations.BackfillTeamsLocked do
  use Ecto.Migration

  def up do
    execute """
    UPDATE teams t
      SET locked = true
      WHERE EXISTS (
        SELECT 1
        FROM sites s
        WHERE s.team_id = t.id
        AND s.locked = true
      );
    """
  end

  def down do
    raise "Irreversible"
  end
end
