"""Offline reference generation from TWO checksum-pinned sources; never used by cloud jobs."""
from pathlib import Path
import argparse
import hashlib
import json
from .admission import LOCK, sources, require
from .catalog import catalog_sql
from .local import Native
from atomic_apply import migration_body

def build(root, write=False):
    root=Path(root);sources(root)
    db=Native()
    try:
        for file in ['bootstrap_local.sql','bootstrap_orders_local.sql']:
            db.psql((root/'supabase/tests'/file).read_text())
        db.execute(migration_body(root))
        auth=json.loads(db.query("set local search_path='';"+catalog_sql(True)+';'))
        db.execute((root/LOCK['path']).read_bytes())
        orders=json.loads(db.query("set local search_path='';"+catalog_sql(orders_only=True)+';'))
        lock=dict(LOCK)
        for kind,document in [('auth',auth),('orders',orders)]:
            raw=(json.dumps(document,ensure_ascii=False,indent=2)+'\n').encode()
            path=root/'tools/orders_migration'/f'{kind}_reference.json'
            digest=hashlib.sha256(raw).hexdigest()
            if write:path.write_bytes(raw);lock[kind+'_catalog_sha256']=digest
            else:require(path.read_bytes()==raw and digest==LOCK[kind+'_catalog_sha256'],'Reference differs; no automatic rewrite.')
        if write:(root/'tools/orders_migration/lock.json').write_text(json.dumps(lock,indent=2)+'\n')
    except Exception:
        print('Synthetic reference diagnostic:',getattr(db,'last_error',''))
        raise
    finally:db.close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--write',action='store_true');a=p.parse_args()
    build(Path(__file__).resolve().parents[2],a.write)
    print('Offline references checked against fixed migration sources.')
