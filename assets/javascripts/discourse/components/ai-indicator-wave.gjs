const indicatorDots = [".", ".", "."];
const AiIndicatorWave = <template>hhhj
  {{#if @loading}}
    <span class="ai-indicator-wave">fg
      {{#each indicatorDots as |dot|}}
        <span class="ai-indicator-wave__dot">{{dot}}</span>
      {{/each}}
    </span>
  {{/if}}
</template>;

export default AiIndicatorWave;
