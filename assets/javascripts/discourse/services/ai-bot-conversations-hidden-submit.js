import { action } from "@ember/object";
import { next } from "@ember/runloop";
import Service, { service } from "@ember/service";
import { tracked } from "@ember-compat/tracked-built-ins";
import { ajax } from "discourse/lib/ajax";
import { getUploadMarkdown } from "discourse/lib/uploads";
import { i18n } from "discourse-i18n";

export default class AiBotConversationsHiddenSubmit extends Service {
  @service appEvents;
  @service composer;
  @service dialog;
  @service router;
  @service siteSettings;

  @tracked loading = false;
  @tracked isPrivate = false;

  personaId;
  targetUsername;

  inputValue = "";

  @action
  focusInput() {
    this.composer.destroyDraft();
    this.composer.close();
    next(() => {
      document.getElementById("ai-bot-conversations-input").focus();
    });
  }

  @action
  async submitToBot(uploadData) {
    if (
      this.inputValue.length <
      this.siteSettings.min_personal_message_post_length
    ) {
      // kuaza
      /*
      Ilk once yazi alanindaki karakter sayisini site ayarlarindaki ile karsilastirirz, ilf ile eger yazi alani yeterli karakterde degilse
      o zaman sonraki asamaya geceriz.
      - upload eidlen bir resim yada dosya varmi kontrol ederiz
      - eger upload alaninda resim varsa hata mesaji cikartmayiz
      - eger resimde yoksa demekki kullanici bos konu gondermeye calisiyor demektir ve uyari cikartiriz
      */

      // eger upload yoksa o zaman yazi alanina birseyler yazilmasi icin uyari veririz.
      if (this.uploads && this.uploads.length < 1) {
        return this.dialog.alert({
          message: i18n(
            "discourse_ai.ai_bot.conversations.min_input_length_message",
            { count: this.siteSettings.min_personal_message_post_length }
          ),
          didConfirm: () => this.focusInput(),
          didCancel: () => this.focusInput(),
        });
      }
    }

    // Don't submit if there are still uploads in progress
    if (uploadData.inProgressUploadsCount > 0) {
      return this.dialog.alert({
        message: i18n("discourse_ai.ai_bot.conversations.uploads_in_progress"),
      });
    }

    this.loading = true;
    //const title = i18n("discourse_ai.ai_bot.default_pm_prefix");
    const saatcik = Date.now();
    const title = '[Geçici başlık] - ' + saatcik;

    // Prepare the raw content with any uploads appended
    let rawContent = this.inputValue;

    // Append upload markdown if we have uploads
    if (uploadData.uploads && uploadData.uploads.length > 0) {
      rawContent += "\n\n";

      uploadData.uploads.forEach((upload) => {
        const uploadMarkdown = getUploadMarkdown(upload);
        rawContent += uploadMarkdown + "\n";
      });
    }

    try {
        const data = {
          raw: rawContent + " --- " + this.isPrivate,
          title,
          archetype: this.isPrivate ? "private_message" : "regular",
          target_recipients: this.targetUsername,
          meta_data: { ai_persona_id: this.personaId },
        };

        if (this.isPrivate === false) {
          data.tags = [
            this.targetUsername,
          ].filter(Boolean);
        }

        const response = await ajax("/posts.json", {
          method: "POST",
          data,
        });


      // Reset uploads after successful submission
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
