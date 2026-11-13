"""Offline JSON request only. Does not dispatch a workflow."""
import argparse
import json
from .admission import LOCK, HEX40, HEX64, require

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('operation',choices=['preview','apply','inspect'])
    p.add_argument('--sha',required=True);p.add_argument('--project-ref',required=True)
    p.add_argument('--preview-run-id',default='');p.add_argument('--backup-sha256',default='')
    a=p.parse_args();require(HEX40.fullmatch(a.sha) and a.project_ref==LOCK['project_ref'],'Fixed project/full commit required.')
    if a.operation=='apply':require(a.preview_run_id.isdigit() and HEX64.fullmatch(a.backup_sha256),'Preview and backup required.')
    print(json.dumps({'ref':LOCK['branch'],'inputs':{'operation':a.operation,'approved_sha':a.sha,
        'project_ref':a.project_ref,'preview_run_id':a.preview_run_id,'backup_sha256':a.backup_sha256}},indent=2))
