import { action } from "@ember/object";
import { next } from "@ember/runloop";
import Service, { service } from "@ember/service";
import { tracked } from "@ember-compat/tracked-built-ins";
import { ajax } from "discourse/lib/ajax";
import { getUploadMarkdown } from "discourse/lib/uploads";
import { i18n } from "discourse-i18n";

export default class AiBotConversationsHiddenSubmit extends Service {
  @service aiConversationsSidebarManager;
  @service appEvents;
  @service composer;
  @service dialog;
  @service router;
  @service siteSettings;

  @tracked loading = false;

  personaId;
  targetUsername;
  uploads = [];

  inputValue = "";
	
  get olusturmazamani() {
    return moment(`${this.date} ${this.time}`, "YYYY-MM-DD HH:mm:ss");
  }
	
  @action
  focusInput() {
    this.composer.destroyDraft();
    this.composer.close();
    next(() => {
      document.getElementById("ai-bot-conversations-input").focus();
    });
  }

  @action
  async submitToBot() {
    if (
      this.inputValue.length <
      this.siteSettings.min_personal_message_post_length
    ) {
      return this.dialog.alert({
        message: i18n(
          "discourse_ai.ai_bot.conversations.min_input_length_message",
          { count: this.siteSettings.min_personal_message_post_length }
        ),
        didConfirm: () => this.focusInput(),
        didCancel: () => this.focusInput(),
      });
    }

    // Don't submit if there are still uploads in progress
    if (document.querySelector(".ai-bot-upload--in-progress")) {
      return this.dialog.alert({
        message: i18n("discourse_ai.ai_bot.conversations.uploads_in_progress"),
      });
    }

    this.loading = true;
    const title = i18n("discourse_ai.ai_bot.default_pm_prefix")+" - "+olusturmazamani;

    // Prepare the raw content with any uploads appended
    let rawContent = this.inputValue;

    // Append upload markdown if we have uploads
    if (this.uploads && this.uploads.length > 0) {
      rawContent += "\n\n";

      this.uploads.forEach((upload) => {
        const uploadMarkdown = getUploadMarkdown(upload);
        rawContent += uploadMarkdown + "\n";
      });
    }

    try {
      const response = await ajax("/posts.json", {
        method: "POST",
        data: {
          raw: rawContent,
          title,
          //archetype: "private_message",
          //target_recipients: this.targetUsername,
          //meta_data: { ai_persona_id: this.personaId },
	create_as_post_voting: true,
	wiki: true,
          //category: 1,
        },
      });

      // Reset uploads after successful submission
      this.uploads = [];
      this.inputValue = "";

      this.appEvents.trigger("discourse-ai:bot-pm-created", {
        id: response.topic_id,
        slug: response.topic_slug,
        title,
      });

      this.router.transitionTo(response.post_url);
    } finally {
      this.loading = false;
    }
  }
}
