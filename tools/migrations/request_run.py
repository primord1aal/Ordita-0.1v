"""Создаёт JSON запроса. Никаких сетевых запросов или запуска Actions."""
import argparse
import json
from policy import LOCK,SHA_PATTERN,REF_PATTERN,require


if __name__=='__main__':
    parser=argparse.ArgumentParser(description='Только подготовка запроса workflow_dispatch, без отправки.')
    parser.add_argument('operation',choices=['preview','apply','inspect'])
    parser.add_argument('--sha',required=True)
    parser.add_argument('--project-ref',required=True)
    parser.add_argument('--preview-run-id',default='')
    parser.add_argument('--backup-sha256',default='')
    args=parser.parse_args()
    require(bool(SHA_PATTERN.fullmatch(args.sha)),'Нужен полный SHA.')
    require(bool(REF_PATTERN.fullmatch(args.project_ref)),'Нужен точный Ref.')
    print(json.dumps({'ref':LOCK['branch'],'inputs':{'migration_operation':args.operation,
        'approved_sha':args.sha,'requested_project_ref':args.project_ref,
        'preview_run_id':args.preview_run_id,'backup_sha256':args.backup_sha256}},ensure_ascii=False,indent=2))
