# frozen_string_literal: true

module DiscourseAi
  module Utils
    module Research
      class Filter
        # Stores custom filter handlers
        def self.register_filter(matcher, &block)
          (@registered_filters ||= {})[matcher] = block
        end

        def self.registered_filters
          @registered_filters ||= {}
        end

        def self.word_to_date(str)
          ::Search.word_to_date(str)
        end

        attr_reader :term, :filters, :order, :guardian, :limit, :offset, :invalid_filters

        # Define all filters at class level
        register_filter(/\Astatus:open\z/i) do |relation, _, _|
          relation.where("topics.closed = false AND topics.archived = false")
        end

        register_filter(/\Astatus:closed\z/i) do |relation, _, _|
          relation.where("topics.closed = true")
        end

        register_filter(/\Astatus:archived\z/i) do |relation, _, _|
          relation.where("topics.archived = true")
        end

        register_filter(/\Astatus:noreplies\z/i) do |relation, _, _|
          relation.where("topics.posts_count = 1")
        end

        register_filter(/\Astatus:single_user\z/i) do |relation, _, _|
          relation.where("topics.participant_count = 1")
        end

        # Date filters
        register_filter(/\Abefore:(.*)\z/i) do |relation, date_str, _|
          if date = Filter.word_to_date(date_str)
            relation.where("posts.created_at < ?", date)
          else
            relation
          end
        end

        register_filter(/\Aafter:(.*)\z/i) do |relation, date_str, _|
          if date = Filter.word_to_date(date_str)
            relation.where("posts.created_at > ?", date)
          else
            relation
          end
        end

        register_filter(/\Atopic_before:(.*)\z/i) do |relation, date_str, _|
          if date = Filter.word_to_date(date_str)
            relation.where("topics.created_at < ?", date)
          else
            relation
          end
        end

        register_filter(/\Atopic_after:(.*)\z/i) do |relation, date_str, _|
          if date = Filter.word_to_date(date_str)
            relation.where("topics.created_at > ?", date)
          else
            relation
          end
        end

        register_filter(/\A(?:tags?|tag):(.*)\z/i) do |relation, tag_param, _|
          if tag_param.include?(",")
            tag_names = tag_param.split(",").map(&:strip)
            tag_ids = Tag.where(name: tag_names).pluck(:id)
            return relation.where("1 = 0") if tag_ids.empty?
            relation.where(topic_id: TopicTag.where(tag_id: tag_ids).select(:topic_id))
          else
            if tag = Tag.find_by(name: tag_param)
              relation.where(topic_id: TopicTag.where(tag_id: tag.id).select(:topic_id))
            else
              relation.where("1 = 0")
            end
          end
        end

        register_filter(/\Akeywords?:(.*)\z/i) do |relation, keywords_param, _|
          if keywords_param.blank?
            relation
          else
            keywords = keywords_param.split(",").map(&:strip).reject(&:blank?)
            if keywords.empty?
              relation
            else
              # Build a ts_query string joined by | (OR)
              ts_query = keywords.map { |kw| kw.gsub(/['\\]/, " ") }.join(" | ")
              relation =
                relation.joins("JOIN post_search_data ON post_search_data.post_id = posts.id")
              relation.where(
                "post_search_data.search_data @@ to_tsquery(?, ?)",
                ::Search.ts_config,
                ts_query,
              )
            end
          end
        end

        register_filter(/\A(?:categories?|category):(.*)\z/i) do |relation, category_param, _|
          if category_param.include?(",")
            category_names = category_param.split(",").map(&:strip)

            found_category_ids = []
            category_names.each do |name|
              category = Category.find_by(slug: name) || Category.find_by(name: name)
              found_category_ids << category.id if category
            end

            return relation.where("1 = 0") if found_category_ids.empty?
            relation.where(topic_id: Topic.where(category_id: found_category_ids).select(:id))
          else
            if category =
                 Category.find_by(slug: category_param) || Category.find_by(name: category_param)
              relation.where(topic_id: Topic.where(category_id: category.id).select(:id))
            else
              relation.where("1 = 0")
            end
          end
        end

        register_filter(/\A\@(\w+)\z/i) do |relation, username, filter|
          user = User.find_by(username_lower: username.downcase)
          if user
            relation.where("posts.user_id = ?", user.id)
          else
            relation.where("1 = 0") # No results if user doesn't exist
          end
        end

        register_filter(/\Ain:posted\z/i) do |relation, _, filter|
          if filter.guardian.user
            relation.where("posts.user_id = ?", filter.guardian.user.id)
          else
            relation.where("1 = 0") # No results if not logged in
          end
        end

        register_filter(/\Agroup:([a-zA-Z0-9_\-]+)\z/i) do |relation, name, filter|
          group = Group.find_by("name ILIKE ?", name)
          if group
            relation.where(
              "posts.user_id IN (
              SELECT gu.user_id FROM group_users gu
              WHERE gu.group_id = ?
            )",
              group.id,
            )
          else
            relation.where("1 = 0") # No results if group doesn't exist
          end
        end

        register_filter(/\Amax_results:(\d+)\z/i) do |relation, limit_str, filter|
          filter.limit_by_user!(limit_str.to_i)
          relation
        end

        register_filter(/\Aorder:latest\z/i) do |relation, order_str, filter|
          filter.set_order!(:latest_post)
          relation
        end

        register_filter(/\Aorder:oldest\z/i) do |relation, order_str, filter|
          filter.set_order!(:oldest_post)
          relation
        end

        register_filter(/\Aorder:latest_topic\z/i) do |relation, order_str, filter|
          filter.set_order!(:latest_topic)
          relation
        end

        register_filter(/\Aorder:oldest_topic\z/i) do |relation, order_str, filter|
          filter.set_order!(:oldest_topic)
          relation
        end

        register_filter(/\Atopics?:(.*)\z/i) do |relation, topic_param, filter|
          if topic_param.include?(",")
            topic_ids = topic_param.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
            return relation.where("1 = 0") if topic_ids.empty?
            filter.always_return_topic_ids!(topic_ids)
            relation
          else
            topic_id = topic_param.to_i
            if topic_id > 0
              filter.always_return_topic_ids!([topic_id])
              relation
            else
              relation.where("1 = 0") # No results if topic_id is invalid
            end
          end
        end

        def initialize(term, guardian: nil, limit: nil, offset: nil)
          @guardian = guardian || Guardian.new
          @limit = limit
          @offset = offset
          @filters = []
          @valid = true
          @order = :latest_post
          @topic_ids = nil
          @invalid_filters = []
          @term = term.to_s.strip

          process_filters(@term)
        end

        def set_order!(order)
          @order = order
        end

        def always_return_topic_ids!(topic_ids)
          if @topic_ids
            @topic_ids = @topic_ids + topic_ids
          else
            @topic_ids = topic_ids
          end
        end

        def limit_by_user!(limit)
          @limit = limit if limit.to_i < @limit.to_i || @limit.nil?
        end

        def search
          filtered =
            Post
              .secured(@guardian)
              .joins(:topic)
              .merge(Topic.secured(@guardian))
              .where("topics.archetype = 'regular'")
          original_filtered = filtered

          @filters.each do |filter_block, match_data|
            filtered = filter_block.call(filtered, match_data, self)
          end

          if @topic_ids.present?
            if original_filtered == filtered
              filtered = original_filtered.where("posts.topic_id IN (?)", @topic_ids)
            else
              filtered =
                original_filtered.where(
                  "posts.topic_id IN (?) OR posts.id IN (?)",
                  @topic_ids,
                  filtered.select("posts.id"),
                )
            end
          end

          filtered = filtered.limit(@limit) if @limit.to_i > 0
          filtered = filtered.offset(@offset) if @offset.to_i > 0

          if @order == :latest_post
            filtered = filtered.order("posts.created_at DESC")
          elsif @order == :oldest_post
            filtered = filtered.order("posts.created_at ASC")
          elsif @order == :latest_topic
            filtered = filtered.order("topics.created_at DESC, posts.post_number DESC")
          elsif @order == :oldest_topic
            filtered = filtered.order("topics.created_at ASC, posts.post_number ASC")
          end

          filtered
        end

        private

        def process_filters(term)
          return if term.blank?

          term
            .to_s
            .scan(/(([^" \t\n\x0B\f\r]+)?(("[^"]+")?))/)
            .to_a
            .map do |(word, _)|
              next if word.blank?

              found = false
              self.class.registered_filters.each do |matcher, block|
                if word =~ matcher
                  @filters << [block, $1]
                  found = true
                  break
                end
              end

              invalid_filters << word if !found
            end
        end
      end
    end
  end
end
