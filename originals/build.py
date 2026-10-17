import sys
src,dst,title,staging=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]=='1'
links=open(sys.argv[5]).read() if len(sys.argv)>5 else ''   # optional script added to the page (e.g. landing-links.js)
t=open(src,encoding='utf-8').read()
t=t.replace('<title>Bundled Page</title>',f'<title>{title}</title>'+('\n  <meta name="robots" content="noindex">' if staging else ''),1)
anchor='<meta name=\\"viewport\\" content=\\"width=device-width, initial-scale=1\\">\\n\\n<script src='
assert t.count(anchor)==1, t.count(anchor)
add=f'\\n<title>{title}<\\u002Ftitle>'
if staging:
    add+='\\n<meta name=\\"robots\\" content=\\"noindex\\">\\n<style>html::after{content:\\"STAGING\\";position:fixed;bottom:10px;left:10px;z-index:2147483647;background:#d32f2f;color:#fff;font:700 11px/1 -apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:.08em;padding:5px 10px;border-radius:999px;pointer-events:none;box-shadow:0 1px 4px rgba(0,0,0,.25)}<\\u002Fstyle>'
if links:
    import json
    add+='\\n<script>'+json.dumps(links)[1:-1].replace('</','<\\u002F')+'<\\u002Fscript>'
i=t.index(anchor)+len('<meta name=\\"viewport\\" content=\\"width=device-width, initial-scale=1\\">')
t=t[:i]+add+t[i:]
open(dst,'w',encoding='utf-8').write(t)
