# frozen_string_literal: true

module Jobs
  class PostLocalizationBackfill < ::Jobs::Scheduled
    every 5.minutes
    cluster_concurrency 1

    def execute(args)
      return if !SiteSetting.discourse_ai_enabled
      return if !SiteSetting.ai_translation_enabled

      return if SiteSetting.content_localization_supported_locales.blank?
      return if SiteSetting.ai_translation_backfill_rate == 0

      Jobs.enqueue(:localize_posts, limit: SiteSetting.ai_translation_backfill_rate)
    end
  end
end
