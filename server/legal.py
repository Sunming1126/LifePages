"""Public pages linked from LifePages and its App Store listing."""

from html import escape
from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter(include_in_schema=False)
PAGES = Path(__file__).with_name('legal_pages')
TITLES = {'privacy': '隐私政策', 'permissions': '权限说明', 'support': '帮助与反馈'}


def page(name):
    title = escape(TITLES[name])
    content = (PAGES / f'{name}.html').read_text(encoding='utf-8')
    nav = ' · '.join(f'<a href="{key}">{escape(label)}</a>' for key, label in TITLES.items() if key != name)
    return HTMLResponse(f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · LifePages</title>
<style>
:root {{ color-scheme: light; background:#f8f5ee; color:#2a2528; font:18px/1.65 system-ui,sans-serif; }}
main {{ max-width:43rem; margin:auto; padding:2.5rem 1.2rem; }}
h1,h2 {{ line-height:1.25; }}
h2 {{ font-size:1.22rem; margin-top:1.65rem; }}
a {{ color:#85442b; overflow-wrap:anywhere; }}
footer {{ border-top:1px solid #d8c9b5; margin-top:2rem; padding-top:1rem; }}
</style></head><body><main>
<header><p>LifePages</p><h1>{title}</h1></header>
{content}
<footer>{nav} · <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Apple 使用条款</a></footer>
</main></body></html>''', headers={'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff'})


@router.get('/privacy')
def privacy():
    return page('privacy')


@router.get('/permissions')
def permissions():
    return page('permissions')


@router.get('/support')
def support():
    return page('support')
