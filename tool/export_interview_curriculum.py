"""Render the published curriculum as a reviewable Chinese document."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.interview_themes import THEMES


def render():
    lines = ['# LifePages v2 隐藏主题与精选题验收细则', '',
             '30 个主题，每主题 4 道精选题，共 120 题。ID 与已发布题面保持稳定；仅新建的 v2 书使用。', '',
             '精选题是不同故事的入口，不要求逐题答完。主题累计有效原话至少 301 字，同时满足核心条件，'
             '至少有一段展开充分的事件、过程或日常场景；当前故事收束后才正常进入下个主题。', '',
             '每题前五项须有充分原话证据，最后一项可按题意不适用。缺项用于寻找有价值的追问，'
             '不是强迫用户交齐信息；记不清或没有这类经历时换入口。', '',
             '用户讲出的故事可以不同于刚问的题面：按同主题里最贴合实际故事的题目细则评估。'
             '不因用户没回答当前角度而丢弃另一段完整经历；充分回答过的题即使未展示也不再问。', '',
             '设计参考：[Smithsonian 访谈指南](https://folklife.si.edu/the-smithsonian-folklife-and-oral-history-interviewing-guide/some-possible-questions/smithsonian)、'
             '[Storyworth 公开题库](https://welcome.storyworth.com/blog/60-storyworth-memoirs-question-prompts)。以下题目为中文原创。', '']
    for theme in THEMES:
        lines.extend([f'## {theme.id} · {theme.direction}', '', f'存在价值：{theme.value}', '',
                      '主题核心条件：' + '；'.join(theme.core) + '。', ''])
        for q in theme.questions:
            lines.extend([f'### {q.id} · {q.prompt}', '', f'本题价值：{q.value}', '',
                          f'适用条件：{q.applicability}', '', f'备用提示：{q.backup}', '',
                          '| 维度 | 充分证据 | 仅有线索的反例 | 深化方向 | 不适用情形 |',
                          '|---|---|---|---|---|'])
            for cell in q.criteria:
                lines.append('| ' + ' | '.join(vars(cell).values()) + ' |')
            lines.append('')
    return '\n'.join(lines).rstrip() + '\n'


if __name__ == '__main__':
    target = Path(__file__).resolve().parents[1] / 'docs/INTERVIEW_V2_CURRICULUM.md'
    target.write_text(render(), encoding='utf-8')
    print(f'{len(THEMES)} themes, {sum(len(t.questions) for t in THEMES)} questions -> {target}')
