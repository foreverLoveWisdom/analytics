defmodule PlausibleWeb.Tracker do
  @moduledoc """
  Helper module for building the dynamic tracker script. Used by PlausibleWeb.TrackerPlug.
  """

  use Plausible
  use Plausible.Repo
  alias Plausible.Site.TrackerScriptConfiguration

  path = Application.app_dir(:plausible, "priv/tracker/js/plausible-web.js")
  # On CI, the file might not be present for static checks so we create an empty one
  File.touch!(path)

  @plausible_main_script File.read!(path)
  @external_resource "priv/tracker/js/plausible-web.js"

  def plausible_main_script_tag(tracker_script_configuration) do
    config_js_content =
      tracker_script_configuration
      |> plausible_main_config()
      |> Enum.flat_map(fn
        {key, value} when is_binary(value) -> ["#{key}:#{JSON.encode!(value)}"]
        # :TRICKY: Save bytes by using short-hand for true
        {key, true} -> ["#{key}:!0"]
        # Not enabled values can be omitted
        {_key, false} -> []
      end)
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.join(",")

    @plausible_main_script
    |> String.replace("\"<%= @config_js %>\"", "{#{config_js_content}}")
  end

  def plausible_main_config(tracker_script_configuration) do
    %{
      domain: tracker_script_configuration.site.domain,
      endpoint: tracker_ingestion_endpoint(),
      outboundLinks: tracker_script_configuration.outbound_links,
      fileDownloads: tracker_script_configuration.file_downloads,
      formSubmissions: tracker_script_configuration.form_submissions
    }
  end

  def update_script_configuration(site, config_update, changeset_type) do
    {:ok, updated_config} =
      Repo.transaction(fn ->
        original_config = get_or_create_tracker_script_configuration!(site)
        changeset = changeset(original_config, config_update, changeset_type)

        updated_config = Repo.update!(changeset)

        sync_goals(site, original_config, updated_config)

        on_ee do
          if Map.keys(changeset.changes) != [:installation_type] do
            Plausible.Workers.PurgeCDNCache.new(
              %{id: updated_config.id},
              # See PurgeCDNCache.ex for more details
              schedule_in: 10,
              replace: [scheduled: [:scheduled_at]]
            )
            |> Oban.insert!()
          end
        end

        updated_config
      end)

    updated_config
  end

  def get_or_create_tracker_script_configuration!(site, params \\ %{}) do
    configuration = Repo.get_by(TrackerScriptConfiguration, site_id: site.id)

    if configuration do
      configuration
    else
      {:ok, created_config} =
        Repo.transaction(fn ->
          created_config =
            TrackerScriptConfiguration.installation_changeset(
              %TrackerScriptConfiguration{site_id: site.id},
              params
            )
            |> Repo.insert!()

          sync_goals(site, %{}, created_config)

          created_config
        end)

      created_config
    end
  end

  # Sync plausible goals with the updated script config
  defp sync_goals(site, original_config, updated_config) do
    [:track_404_pages, :outbound_links, :file_downloads, :form_submissions]
    |> Enum.map(fn key ->
      {key, Map.get(original_config, key, false), Map.get(updated_config, key, false)}
    end)
    |> Enum.each(fn
      {:track_404_pages, false, true} -> Plausible.Goals.create_404(site)
      {:track_404_pages, true, false} -> Plausible.Goals.delete_404(site)
      {:outbound_links, false, true} -> Plausible.Goals.create_outbound_links(site)
      {:outbound_links, true, false} -> Plausible.Goals.delete_outbound_links(site)
      {:file_downloads, false, true} -> Plausible.Goals.create_file_downloads(site)
      {:file_downloads, true, false} -> Plausible.Goals.delete_file_downloads(site)
      {:form_submissions, false, true} -> Plausible.Goals.create_form_submissions(site)
      {:form_submissions, true, false} -> Plausible.Goals.delete_form_submissions(site)
      _ -> nil
    end)
  end

  defp changeset(tracker_script_configuration, config_update, :installation) do
    TrackerScriptConfiguration.installation_changeset(tracker_script_configuration, config_update)
  end

  defp changeset(tracker_script_configuration, config_update, :plugins_api) do
    TrackerScriptConfiguration.plugins_api_changeset(tracker_script_configuration, config_update)
  end

  defp tracker_ingestion_endpoint() do
    # :TRICKY: Normally we would use PlausibleWeb.Endpoint.url() here, but
    # that requires the endpoint to be started. We start the TrackerScriptCache
    # before the endpoint is started, so we need to use the base_url directly.

    endpoint_config = Application.fetch_env!(:plausible, PlausibleWeb.Endpoint)
    base_url = Keyword.get(endpoint_config, :base_url)
    "#{base_url}/api/event"
  end
end
