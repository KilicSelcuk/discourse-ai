# frozen_string_literal: true
module DiscourseAi
  module Automation
    module LlmAgentTriage
      def self.handle(post:, agent_id:, whisper: false, silent_mode: false, automation: nil)
        DiscourseAi::AiBot::Playground.reply_to_post(
          post: post,
          agent_id: agent_id,
          whisper: whisper,
          silent_mode: silent_mode,
          feature_name: "automation - #{automation&.name}",
        )
      rescue => e
        Discourse.warn_exception(
          e,
          message: "Error responding to: #{post&.url} in LlmAgentTriage.handle",
        )
        raise e if Rails.env.test?
        nil
      end
    end
  end
end
