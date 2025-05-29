import Component from "@glimmer/component";
import { cached, tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { LinkTo } from "@ember/routing";
import { later } from "@ember/runloop";
import { service } from "@ember/service";
import { gt, or } from "truth-helpers";
import BackButton from "discourse/components/back-button";
import Form from "discourse/components/form";
import Avatar from "discourse/helpers/bound-avatar-template";
import { popupAjaxError } from "discourse/lib/ajax-error";
import Group from "discourse/models/group";
import { i18n } from "discourse-i18n";
import AdminUser from "admin/models/admin-user";
import GroupChooser from "select-kit/components/group-chooser";
import AiAgentResponseFormatEditor from "../components/modal/ai-agent-response-format-editor";
import AiLlmSelector from "./ai-llm-selector";
import AiAgentCollapsableExample from "./ai-agent-example";
import AiAgentToolOptions from "./ai-agent-tool-options";
import AiToolSelector from "./ai-tool-selector";
import RagOptionsFk from "./rag-options-fk";
import RagUploader from "./rag-uploader";

export default class AgentEditor extends Component {
  @service router;
  @service store;
  @service dialog;
  @service toasts;
  @service siteSettings;

  @tracked allGroups = [];
  @tracked isSaving = false;

  dirtyFormData = null;

  @cached
  get formData() {
    // This is to recover a dirty state after persisting a single form field.
    // It's meant to be consumed only once.
    if (this.dirtyFormData) {
      const data = this.dirtyFormData;
      this.dirtyFormData = null;
      return data;
    } else {
      const data = this.args.model.toPOJO();

      if (data.tools) {
        data.toolOptions = this.mapToolOptions(data.toolOptions, data.tools);
      }

      return data;
    }
  }

  get chatPluginEnabled() {
    return this.siteSettings.chat_enabled;
  }

  get allTools() {
    return this.args.agents.resultSetMeta.tools;
  }

  get maxPixelValues() {
    const l = (key) =>
      i18n(`discourse_ai.ai_agent.vision_max_pixel_sizes.${key}`);
    return [
      { name: l("low"), id: 65536 },
      { name: l("medium"), id: 262144 },
      { name: l("high"), id: 1048576 },
    ];
  }

  get forcedToolStrategies() {
    const content = [
      {
        id: -1,
        name: i18n("discourse_ai.ai_agent.tool_strategies.all"),
      },
    ];

    [1, 2, 5].forEach((i) => {
      content.push({
        id: i,
        name: i18n("discourse_ai.ai_agent.tool_strategies.replies", {
          count: i,
        }),
      });
    });

    return content;
  }

  @action
  async updateAllGroups() {
    const groups = await Group.findAll({ include_everyone: true });

    // Backwards-compatibility code. TODO(roman): Remove 01-09-2025
    const hasEveryoneGroup = groups.find((g) => g.id === 0);
    if (!hasEveryoneGroup) {
      const everyoneGroupName = "everyone";
      groups.push({ id: 0, name: everyoneGroupName });
    }

    this.allGroups = groups;
  }

  @action
  async save(data) {
    const isNew = this.args.model.isNew;
    this.isSaving = true;

    try {
      const agentToSave = Object.assign(
        this.args.model,
        this.args.model.fromPOJO(data)
      );

      await agentToSave.save();
      this.#sortAgents();

      if (isNew && this.args.model.rag_uploads.length === 0) {
        this.args.agents.addObject(agentToSave);
        this.router.transitionTo(
          "adminPlugins.show.discourse-ai-agents.edit",
          agentToSave
        );
      } else {
        this.toasts.success({
          data: { message: i18n("discourse_ai.ai_agent.saved") },
          duration: 2000,
        });
      }
    } catch (e) {
      popupAjaxError(e);
    } finally {
      later(() => {
        this.isSaving = false;
      }, 1000);
    }
  }

  get adminUser() {
    // Work around user not being extensible.
    const userClone = Object.assign({}, this.args.model?.user);

    return AdminUser.create(userClone);
  }

  @action
  delete() {
    return this.dialog.confirm({
      message: i18n("discourse_ai.ai_agent.confirm_delete"),
      didConfirm: () => {
        return this.args.model.destroyRecord().then(() => {
          this.args.agents.removeObject(this.args.model);
          this.router.transitionTo(
            "adminPlugins.show.discourse-ai-agents.index"
          );
        });
      },
    });
  }

  @action
  async toggleEnabled(dirtyData, value, { set }) {
    set("enabled", value);
    await this.persistField(dirtyData, "enabled", value);
  }

  @action
  async togglePriority(dirtyData, value, { set }) {
    set("priority", value);
    await this.persistField(dirtyData, "priority", value, true);
  }

  @action
  async createUser(form) {
    try {
      let user = await this.args.model.createUser();
      form.set("user", user);
      form.set("user_id", user.id);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  updateUploads(form, newUploads) {
    form.set("rag_uploads", newUploads);
  }

  @action
  async removeUpload(form, dirtyData, currentUploads, upload) {
    const updatedUploads = currentUploads.filter(
      (file) => file.id !== upload.id
    );

    form.set("rag_uploads", updatedUploads);

    if (!this.args.model.isNew) {
      await this.persistField(dirtyData, "rag_uploads", updatedUploads);
    }
  }

  @action
  updateToolNames(form, currentData, updatedTools) {
    const removedTools =
      currentData?.tools?.filter((ct) => !updatedTools.includes(ct)) || [];
    const updatedOptions = this.mapToolOptions(
      currentData.toolOptions,
      updatedTools
    );

    form.setProperties({
      tools: updatedTools,
      toolOptions: updatedOptions,
    });

    if (currentData.forcedTools?.length > 0) {
      const updatedForcedTools = currentData.forcedTools.filter(
        (fct) => !removedTools.includes(fct)
      );
      form.set("forcedTools", updatedForcedTools);
    }
  }

  @action
  availableForcedTools(tools) {
    return this.allTools.filter((tool) => tools.includes(tool.id));
  }

  @action
  addExamplesPair(form, data) {
    const newExamples = [...data.examples, ["", ""]];
    form.set("examples", newExamples);
  }

  mapToolOptions(currentOptions, toolNames) {
    const updatedOptions = Object.assign({}, currentOptions);

    toolNames.forEach((toolId) => {
      const tool = this.allTools.findBy("id", toolId);
      const toolOptions = tool?.options;

      if (!toolOptions || updatedOptions[toolId]) {
        return;
      }

      const mappedOptions = {};
      Object.keys(toolOptions).forEach((key) => {
        mappedOptions[key] = null;
      });

      updatedOptions[toolId] = mappedOptions;
    });

    return updatedOptions;
  }

  async persistField(dirtyData, field, newValue, sortAgents) {
    if (!this.args.model.isNew) {
      const updatedDirtyData = Object.assign({}, dirtyData);
      updatedDirtyData[field] = newValue;

      try {
        const args = {};
        args[field] = newValue;

        this.dirtyFormData = updatedDirtyData;
        await this.args.model.update(args);
        if (sortAgents) {
          this.#sortAgents();
        }
      } catch (e) {
        popupAjaxError(e);
      }
    }
  }

  #sortAgents() {
    const sorted = this.args.agents.toArray().sort((a, b) => {
      if (a.priority && !b.priority) {
        return -1;
      } else if (!a.priority && b.priority) {
        return 1;
      } else {
        return a.name.localeCompare(b.name);
      }
    });
    this.args.agents.clear();
    this.args.agents.setObjects(sorted);
  }

  <template>
    <BackButton
      @route="adminPlugins.show.discourse-ai-agents"
      @label="discourse_ai.ai_agent.back"
    />
    <div class="ai-agent-editor" {{didInsert this.updateAllGroups @model.id}}>
      <Form @onSubmit={{this.save}} @data={{this.formData}} as |form data|>
        <form.Field
          @name="name"
          @title={{i18n "discourse_ai.ai_agent.name"}}
          @validation="required|length:1,100"
          @disabled={{data.system}}
          @format="large"
          as |field|
        >
          <field.Input />
        </form.Field>

        <form.Field
          @name="description"
          @title={{i18n "discourse_ai.ai_agent.description"}}
          @validation="required|length:1,100"
          @disabled={{data.system}}
          @format="large"
          as |field|
        >
          <field.Textarea />
        </form.Field>

        <form.Field
          @name="system_prompt"
          @title={{i18n "discourse_ai.ai_agent.system_prompt"}}
          @validation="required|length:1,100000"
          @disabled={{data.system}}
          @format="large"
          as |field|
        >
          <field.Textarea />
        </form.Field>

        <AiAgentResponseFormatEditor @form={{form}} @data={{data}} />

        <form.Field
          @name="default_llm_id"
          @title={{i18n "discourse_ai.ai_agent.default_llm"}}
          @tooltip={{i18n "discourse_ai.ai_agent.default_llm_help"}}
          @format="large"
          as |field|
        >
          <field.Custom>
            <AiLlmSelector
              @value={{field.value}}
              @llms={{@agents.resultSetMeta.llms}}
              @onChange={{field.set}}
              @class="ai-agent-editor__llms"
            />
          </field.Custom>
        </form.Field>

        <form.Field
          @name="allowed_group_ids"
          @title={{i18n "discourse_ai.ai_agent.allowed_groups"}}
          @format="large"
          as |field|
        >
          <field.Custom>
            <GroupChooser
              @value={{data.allowed_group_ids}}
              @content={{this.allGroups}}
              @onChange={{field.set}}
            />
          </field.Custom>
        </form.Field>

        <form.Field
          @name="vision_enabled"
          @title={{i18n "discourse_ai.ai_agent.vision_enabled"}}
          @tooltip={{i18n "discourse_ai.ai_agent.vision_enabled_help"}}
          @format="large"
          as |field|
        >
          <field.Checkbox />
        </form.Field>

        {{#if data.vision_enabled}}
          <form.Field
            @name="vision_max_pixels"
            @title={{i18n "discourse_ai.ai_agent.vision_max_pixels"}}
            @onSet={{this.onChangeMaxPixels}}
            @format="large"
            as |field|
          >
            <field.Select @includeNone={{false}} as |select|>
              {{#each this.maxPixelValues as |pixelValue|}}
                <select.Option
                  @value={{pixelValue.id}}
                >{{pixelValue.name}}</select.Option>
              {{/each}}
            </field.Select>
          </form.Field>
        {{/if}}

        <form.Field
          @name="max_context_posts"
          @title={{i18n "discourse_ai.ai_agent.max_context_posts"}}
          @tooltip={{i18n "discourse_ai.ai_agent.max_context_posts_help"}}
          @format="large"
          as |field|
        >
          <field.Input @type="number" lang="en" />
        </form.Field>

        {{#unless data.system}}
          <form.Field
            @name="temperature"
            @title={{i18n "discourse_ai.ai_agent.temperature"}}
            @tooltip={{i18n "discourse_ai.ai_agent.temperature_help"}}
            @disabled={{data.system}}
            @format="large"
            as |field|
          >
            <field.Input @type="number" step="any" lang="en" />
          </form.Field>

          <form.Field
            @name="top_p"
            @title={{i18n "discourse_ai.ai_agent.top_p"}}
            @tooltip={{i18n "discourse_ai.ai_agent.top_p_help"}}
            @disabled={{data.system}}
            @format="large"
            as |field|
          >
            <field.Input @type="number" step="any" lang="en" />
          </form.Field>
        {{/unless}}

        <form.Section
          @title={{i18n "discourse_ai.ai_agent.examples.title"}}
          @subtitle={{i18n "discourse_ai.ai_agent.examples.examples_help"}}
        >
          {{#unless data.system}}
            <form.Container>
              <form.Button
                @action={{fn this.addExamplesPair form data}}
                @label="discourse_ai.ai_agent.examples.new"
                class="ai-agent-editor__new_example"
              />
            </form.Container>
          {{/unless}}

          {{#if (gt data.examples.length 0)}}
            <form.Collection @name="examples" as |exCollection exCollectionIdx|>
              <AiAgentCollapsableExample
                @examplesCollection={{exCollection}}
                @exampleNumber={{exCollectionIdx}}
                @system={{data.system}}
                @form={{form}}
              />
            </form.Collection>
          {{/if}}
        </form.Section>

        <form.Section @title={{i18n "discourse_ai.ai_agent.ai_tools"}}>
          <form.Field
            @name="tools"
            @title={{i18n "discourse_ai.ai_agent.tools"}}
            @format="large"
            as |field|
          >
            <field.Custom>
              <AiToolSelector
                @value={{field.value}}
                @disabled={{data.system}}
                @onChange={{fn this.updateToolNames form data}}
                @content={{@agents.resultSetMeta.tools}}
              />
            </field.Custom>
          </form.Field>

          {{#if (gt data.tools.length 0)}}
            <form.Field
              @name="forcedTools"
              @title={{i18n "discourse_ai.ai_agent.forced_tools"}}
              @format="large"
              as |field|
            >
              <field.Custom>
                <AiToolSelector
                  @value={{field.value}}
                  @disabled={{data.system}}
                  @onChange={{field.set}}
                  @content={{this.availableForcedTools data.tools}}
                />
              </field.Custom>
            </form.Field>
          {{/if}}

          {{#if (gt data.forcedTools.length 0)}}
            <form.Field
              @name="forced_tool_count"
              @title={{i18n "discourse_ai.ai_agent.forced_tool_strategy"}}
              @format="large"
              as |field|
            >
              <field.Select @includeNone={{false}} as |select|>
                {{#each this.forcedToolStrategies as |fts|}}
                  <select.Option @value={{fts.id}}>{{fts.name}}</select.Option>
                {{/each}}
              </field.Select>
            </form.Field>
          {{/if}}

          {{#if (gt data.tools.length 0)}}
            <form.Field
              @name="tool_details"
              @title={{i18n "discourse_ai.ai_agent.tool_details"}}
              @tooltip={{i18n "discourse_ai.ai_agent.tool_details_help"}}
              @format="large"
              as |field|
            >
              <field.Checkbox />
            </form.Field>

            <AiAgentToolOptions
              @form={{form}}
              @data={{data}}
              @llms={{@agents.resultSetMeta.llms}}
              @allTools={{@agents.resultSetMeta.tools}}
            />
          {{/if}}
        </form.Section>

        {{#if this.siteSettings.ai_embeddings_enabled}}
          <form.Section @title={{i18n "discourse_ai.rag.title"}}>
            <form.Field
              @name="rag_uploads"
              @title={{i18n "discourse_ai.rag.uploads.title"}}
              as |field|
            >
              <field.Custom>
                <RagUploader
                  @target={{data}}
                  @targetName="AiAgent"
                  @updateUploads={{fn this.updateUploads form}}
                  @onRemove={{fn this.removeUpload form data field.value}}
                  @allowImages={{@agents.resultSetMeta.settings.rag_images_enabled}}
                />
              </field.Custom>
            </form.Field>

            <RagOptionsFk
              @form={{form}}
              @data={{data}}
              @llms={{@agents.resultSetMeta.llms}}
              @allowImages={{@agents.resultSetMeta.settings.rag_images_enabled}}
            >
              <form.Field
                @name="rag_conversation_chunks"
                @title={{i18n
                  "discourse_ai.ai_agent.rag_conversation_chunks"
                }}
                @tooltip={{i18n
                  "discourse_ai.ai_agent.rag_conversation_chunks_help"
                }}
                @format="large"
                as |field|
              >
                <field.Input @type="number" step="any" lang="en" />
              </form.Field>

              <form.Field
                @name="question_consolidator_llm_id"
                @title={{i18n
                  "discourse_ai.ai_agent.question_consolidator_llm"
                }}
                @tooltip={{i18n
                  "discourse_ai.ai_agent.question_consolidator_llm_help"
                }}
                @format="large"
                as |field|
              >
                <field.Custom>
                  <AiLlmSelector
                    @value={{field.value}}
                    @llms={{@agents.resultSetMeta.llms}}
                    @onChange={{field.set}}
                    @class="ai-agent-editor__llms"
                  />
                </field.Custom>
              </form.Field>
            </RagOptionsFk>
          </form.Section>
        {{/if}}

        <form.Section @title={{i18n "discourse_ai.ai_agent.ai_bot.title"}}>
          <form.Field
            @name="enabled"
            @title={{i18n "discourse_ai.ai_agent.enabled"}}
            @onSet={{fn this.toggleEnabled data}}
            as |field|
          >
            <field.Toggle />
          </form.Field>

          <form.Field
            @name="priority"
            @title={{i18n "discourse_ai.ai_agent.priority"}}
            @onSet={{fn this.togglePriority data}}
            @tooltip={{i18n "discourse_ai.ai_agent.priority_help"}}
            as |field|
          >
            <field.Toggle />
          </form.Field>

          {{#if @model.isNew}}
            <div>{{i18n "discourse_ai.ai_agent.ai_bot.save_first"}}</div>
          {{else}}
            {{#if data.default_llm_id}}
              <form.Field
                @name="force_default_llm"
                @title={{i18n "discourse_ai.ai_agent.force_default_llm"}}
                @format="large"
                as |field|
              >
                <field.Checkbox />
              </form.Field>
            {{/if}}

            <form.Container
              @title={{i18n "discourse_ai.ai_agent.user"}}
              @tooltip={{unless
                data.user
                (i18n "discourse_ai.ai_agent.create_user_help")
              }}
              class="ai-agent-editor__ai_bot_user"
            >
              {{#if data.user}}
                <a
                  class="avatar"
                  href={{data.user.path}}
                  data-user-card={{data.user.username}}
                >
                  {{Avatar data.user.avatar_template "small"}}
                </a>
                <LinkTo @route="adminUser" @model={{this.adminUser}}>
                  {{data.user.username}}
                </LinkTo>
              {{else}}
                <form.Button
                  @action={{fn this.createUser form}}
                  @label="discourse_ai.ai_agent.create_user"
                  class="ai-agent-editor__create-user"
                />
              {{/if}}
            </form.Container>

            {{#if data.user}}
              <form.Field
                @name="allow_agentl_messages"
                @title={{i18n
                  "discourse_ai.ai_agent.allow_agentl_messages"
                }}
                @tooltip={{i18n
                  "discourse_ai.ai_agent.allow_agentl_messages_help"
                }}
                @format="large"
                as |field|
              >
                <field.Checkbox />
              </form.Field>

              <form.Field
                @name="allow_topic_mentions"
                @title={{i18n "discourse_ai.ai_agent.allow_topic_mentions"}}
                @tooltip={{i18n
                  "discourse_ai.ai_agent.allow_topic_mentions_help"
                }}
                @format="large"
                as |field|
              >
                <field.Checkbox />
              </form.Field>

              {{#if this.chatPluginEnabled}}
                <form.Field
                  @name="allow_chat_direct_messages"
                  @title={{i18n
                    "discourse_ai.ai_agent.allow_chat_direct_messages"
                  }}
                  @tooltip={{i18n
                    "discourse_ai.ai_agent.allow_chat_direct_messages_help"
                  }}
                  @format="large"
                  as |field|
                >
                  <field.Checkbox />
                </form.Field>

                <form.Field
                  @name="allow_chat_channel_mentions"
                  @title={{i18n
                    "discourse_ai.ai_agent.allow_chat_channel_mentions"
                  }}
                  @tooltip={{i18n
                    "discourse_ai.ai_agent.allow_chat_channel_mentions_help"
                  }}
                  @format="large"
                  as |field|
                >
                  <field.Checkbox />
                </form.Field>
              {{/if}}
            {{/if}}
          {{/if}}
        </form.Section>

        <form.Actions>
          <form.Submit />

          {{#unless (or @model.isNew @model.system)}}
            <form.Button
              @action={{this.delete}}
              @label="discourse_ai.ai_agent.delete"
              class="btn-danger"
            />
          {{/unless}}
        </form.Actions>
      </Form>
    </div>
  </template>
}
