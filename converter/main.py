import argparse
import json
import os
import time
import traceback
from pathlib import Path

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source');parser.add_argument('--out')
    parser.add_argument('--index',action='store_true');parser.add_argument('--serve',action='store_true')
    parser.add_argument('--mesh', action='store_true')
    parser.add_argument('--gaussian', action='store_true')
    parser.add_argument('--up', default='z')
    parser.add_argument('--compatible-cpu',action='store_true')
    parser.add_argument('--cache');parser.add_argument('--session');parser.add_argument('--parent',type=int)
    parser.add_argument('--limit',type=int,default=100000);parser.add_argument('--unit',default='m')
    args=parser.parse_args()
    if args.serve:
        if not all((args.cache,args.session,args.parent)):parser.error('服务需要cache/session/parent')
        from converter.worker import serve
        return serve(args.cache,args.session,args.parent) or 0
    if not args.source or not args.out:parser.error('导入需要source/out')
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    def status(value):
        f=out/'status.json';tmp=out/'status.json.tmp'
        tmp.write_text(json.dumps(value,ensure_ascii=False),encoding='utf-8')
        deadline = time.monotonic() + 3
        while True:
            try:
                os.replace(tmp, f)
                return
            except PermissionError as error:
                # A Windows reader can temporarily prevent atomic replacement.
                if getattr(error, 'winerror', None) not in (5, 32, 33) or time.monotonic() >= deadline:
                    raise
                time.sleep(.05)
    last=[0]
    def progress(count):
        now=time.monotonic()
        if now-last[0]>.5:
            status(dict(state='reading',**count) if isinstance(count,dict) else {'state':'reading','read_points':count})
            last[0]=now
    try:
        policy=None
        if args.compatible_cpu:
            from converter.compatibility import enable_compatible_cpu
            policy=enable_compatible_cpu()
        status({'state':'reading','read_points':0})
        if args.mesh:
            from converter.mesh import prepare_mesh
            result = prepare_mesh(args.source, out, args.unit, args.up)
            status(dict(state='complete', **result))
            return 0
        if args.gaussian:
            from converter.gaussian import prepare_gaussian
            m = prepare_gaussian(args.source, out, args.unit, progress)
        elif args.index:
            from converter.full_index import build_index
            m=build_index(args.source,out,preview_limit=args.limit,unit=args.unit,progress=progress)
        else:
            from converter.cloud import convert
            m=convert(args.source,out,args.limit,args.unit,progress)
        if policy:
            from converter.full_index import atomic_json
            m['import_policy']=policy;atomic_json(out/'cloud.json',m)
        status({'state':'complete','display_points':m['display_points'],'valid_points':m['valid_points']})
        return 0
    except Exception as e:
        (out/'error.log').write_text(traceback.format_exc(),encoding='utf-8')
        status({'state':'error','message':str(e)})
        return 1

if __name__=='__main__':raise SystemExit(main())
