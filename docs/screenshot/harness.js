// 截图用：只往页面里灌虚构的演示数据，不改产品代码
(function () {
  const scene = (location.hash || '#home').slice(1).split('-')[0];
  const now = Date.now() / 1000;
  setTimeout(() => {
    onAgent({ type: 'history', current: 'a', items: [
      { id: 'a', title: '整理今天的待办', updated: now - 600 },
      { id: 'b', title: '把 Notion 里的访谈记录同步进知识库', updated: now - 3600 * 3 },
      { id: 'c', title: '帮我写一版产品发布推文', updated: now - 86400, backend: 'codex' },
      { id: 'd', title: '今天学什么？', updated: now - 86400 * 2 } ] });
    if (scene === 'chat') {
      onAgent({ type: 'transcript', events: [
        { type: 'me', text: '看一下我今天和明天的日程，按时间列出来，再帮我列个待办' }, { type: 'start' },
        { type: 'tool', name: 'Bash', input: { command: 'lark-cli calendar +agenda' } },
        { type: 'tool', name: 'mcp__claude_ai_Notion__notion-search', input: {} },
        { type: 'text', text: '## 今明两天\n\n| 时间 | 事项 | 备注 |\n|---|---|---|\n| 今天 10:00 | 产品周会 | 会议室 A |\n| 今天 15:00 | 用户访谈 #3 | 访谈提纲在知识库里 |\n| 明天 14:00 | **客户演示** | 记得带上新版 Demo |\n\n**今天的待办**\n\n- [x] 回复合作方的邮件\n- [ ] 整理周会要讨论的三个问题\n- [ ] 准备客户演示的 Demo\n- [ ] 把访谈记录同步进知识库' },
        { type: 'end' } ] });
    }
    if (scene === 'study') {
      const d = { title: '产品增长 6 周课表', doc: 'https://example.com',
        stages: [{ name: '增长基础', weeks: 'W1–2', days: 14 }, { name: '用户研究', weeks: 'W3', days: 7 }, { name: '渠道与内容', weeks: 'W4–5', days: 14 }, { name: '增长实验', weeks: 'W6', days: 7 }],
        totalDays: 42, actualDay: 9, expectedDay: 12, actual: '增长基础 W2 第 2 天', expected: '增长基础 W2 第 5 天', gapDays: 3,
        queue: [
          { date: '10/24 周五', topic: '漏斗与北极星指标', where: '增长基础 W2 第 3 天', status: 'today', read: '《增长黑客》第 4 章', resource: 'Reforge 北极星指标文章', output: '给自己的产品画一张漏斗' },
          { date: '10/25 周六', topic: '留存曲线', where: '增长基础 W2 第 4 天', status: 'next', read: '留存分析入门', resource: '一份公开的留存数据集', output: '画出 3 条留存曲线并解读' },
          { date: '10/26 周日', topic: '输出日：一页纸', where: '增长基础 W2 第 5 天', status: 'todo', output: '一页纸总结本周所学' } ],
        note: '落后 3 天，按顺序一天一天补就好' };
      onAgent({ type: 'transcript', events: [
        { type: 'me', text: '今天学什么？' }, { type: 'start' },
        { type: 'tool', name: 'Read', input: { file_path: 'prompts/study.md' } },
        { type: 'text', text: '```study\n' + JSON.stringify(d) + '\n```' }, { type: 'end' } ] });
    }
    if (scene === 'kb') {
      setView('kb');
      const it = (id, title, type, source, tags, summary, section, created, status) => ({ id, title, type, source, tags, summary, section, created, status: status || 'ok', url: 'https://example.com', ts: now, canOpen: true });
      onAgent({ type: 'kb', sections: [{ name: '工作', subs: ['项目', '调研'] }, { name: '学习', subs: ['笔记', '课程'] }], items: [
        it('_inbox/a.md', 'https://example.com/blog/launch-retro', 'link', 'https://example.com/blog/launch-retro', [], '', '待定', '2026-10-27', 'raw'),
        it('工作/调研/b.md', 'AI 产品冷启动：从 0 到 1000 个用户', 'file', 'cold-start-playbook.pdf', ['冷启动', '增长', 'AI 产品'], '拆解 5 个 AI 产品的冷启动路径，总结种子用户、内容、社区三种打法。', '工作/调研', '2026-10-27'),
        it('工作/项目/c.md', '用户访谈提纲模板', 'link', '飞书 · 产品资料', ['用户研究', '访谈'], '30 分钟访谈的问题清单，按「背景 → 痛点 → 现有方案 → 付费意愿」组织。', '工作/项目', '2026-10-26'),
        it('学习/笔记/d.md', '和设计师聊首页改版的三个结论', 'note', 'flomo', ['设计', '首页'], '首屏只讲一件事；快捷入口不超过 4 个；空状态要给下一步。', '学习/笔记', '2026-10-25'),
        it('学习/笔记/e.md', '读书笔记：《精益创业》第 3 章', 'note', 'Obsidian · 读书', ['精益创业', 'MVP'], '用最小可行产品验证最危险的假设，而不是验证最容易的那个。', '学习/笔记', '2026-10-24'),
        it('学习/课程/f.md', 'Product Hunt 发布复盘', 'link', 'Notion', ['发布', 'Product Hunt'], '发布当天前 4 小时决定排名：提前预热、准备好评论区回复。', '学习/课程', '2026-10-22') ] });
    }
  }, 400);
})();
