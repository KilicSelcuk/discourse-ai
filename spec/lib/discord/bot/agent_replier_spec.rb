# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAi::Discord::Bot::AgentReplier do
  let(:interaction_body) do
    { data: { options: [{ value: "test query" }] }, token: "interaction_token" }.to_json.to_s
  end
  let(:agent_replier) { described_class.new(interaction_body) }

  fab!(:llm_model)
  fab!(:agent) { Fabricate(:ai_agent, default_llm_id: llm_model.id) }

  before do
    SiteSetting.ai_discord_search_agent = agent.id.to_s
    allow_any_instance_of(DiscourseAi::Agents::Bot).to receive(:reply).and_return(
      "This is a reply from bot!",
    )
    allow(agent_replier).to receive(:create_reply)
  end

  describe "#handle_interaction!" do
    it "creates and updates replies" do
      agent_replier.handle_interaction!
      expect(agent_replier).to have_received(:create_reply).at_least(:once)
    end
  end
end
