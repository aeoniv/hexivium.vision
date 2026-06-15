import json, sys

path = sys.argv[1]
d = json.load(open(path, encoding='utf-8'))
nodes = {n['id']: n for n in d['nodes']}
links = {l[0]: l for l in d['links']}  # link_id -> [id, src_node, src_slot, dst_node, dst_slot, type]

# Build SetNode name -> node id (SetNode stores var name in widgets_values[0])
set_by_name = {}
for n in d['nodes']:
    if n['type'] == 'SetNode':
        nm = (n.get('widgets_values') or [None])[0]
        set_by_name[nm] = n

def out_name(node, slot):
    outs = node.get('outputs') or []
    if slot is not None and slot < len(outs):
        return outs[slot].get('name', f'o{slot}')
    return f'o{slot}'

def resolve(src_id, src_slot, depth=0):
    """Follow Reroute/GetNode virtual nodes to a real source. Returns (node, out_label)."""
    if src_id is None or depth > 12:
        return None, '?'
    node = nodes.get(src_id)
    if not node:
        return None, '?'
    t = node['type']
    if t == 'Reroute':
        ins = node.get('inputs') or []
        if ins and ins[0].get('link') is not None:
            l = links[ins[0]['link']]
            return resolve(l[1], l[2], depth+1)
        return node, 'reroute'
    if t == 'GetNode':
        nm = (node.get('widgets_values') or [None])[0]
        sn = set_by_name.get(nm)
        if sn:
            ins = sn.get('inputs') or []
            if ins and ins[0].get('link') is not None:
                l = links[ins[0]['link']]
                return resolve(l[1], l[2], depth+1)
        return node, f'Get[{nm}]'
    return node, out_name(node, src_slot)

CORE = {'WanVideoModelLoader','WanVideoSetLoRAs','WanVideoLoraSelectMulti','WanVideoSetBlockSwap',
        'WanVideoBlockSwap','WanVideoTextEncodeCached','WanVideoTextEncode','WanVideoClipVisionEncode',
        'WanVideoAnimateEmbeds','WanVideoSampler','WanVideoDecode','WanVideoVAELoader','CLIPVisionLoader',
        'VHS_LoadVideo','LoadImage','VHS_VideoCombine','OnnxDetectionModelLoader','PoseAndFaceDetection',
        'DrawViTPose','WanVideoContextOptions','WanVideoTorchCompileSettings','ImageResizeKJv2',
        'GetImageSizeAndCount'}

def short(v):
    s = repr(v)
    return s if len(s) <= 90 else s[:90] + '...'

out = open('_inspect/wiring.txt', 'w', encoding='utf-8')
for n in d['nodes']:
    if n['type'] not in CORE:
        continue
    title = n.get('title') or n['type']
    out.write(f"\n[{n['id']}] {n['type']}  ({title})\n")
    wv = n.get('widgets_values')
    if isinstance(wv, list):
        out.write(f"    widgets_values = [{', '.join(short(x) for x in wv)}]\n")
    elif wv is not None:
        out.write(f"    widgets_values = {short(wv)}\n")
    for inp in (n.get('inputs') or []):
        nm = inp.get('name')
        lk = inp.get('link')
        if lk is None:
            out.write(f"    in  {nm}: (none)\n")
        else:
            l = links.get(lk)
            src, lbl = resolve(l[1], l[2])
            srcdesc = f"{src['id']} {src['type']}.{lbl}" if src else '?'
            out.write(f"    in  {nm} <- {srcdesc}\n")
out.close()
print('wrote _inspect/wiring.txt')
