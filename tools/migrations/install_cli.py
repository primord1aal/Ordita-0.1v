"""Загрузка только официального архива CLI; до выдачи любых секретов БД."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import tarfile
import urllib.request

LOCK=json.loads((Path(__file__).parent/'lock.json').read_text())


def install(destination):
    destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    archive=destination/LOCK['cli_archive']
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest()!=LOCK['cli_sha256']:
        url=f"https://github.com/supabase/cli/releases/download/v{LOCK['cli_version']}/{LOCK['cli_archive']}"
        request=urllib.request.Request(url,headers={'User-Agent':'orbita-migration-installer'})
        with urllib.request.urlopen(request,timeout=60) as response,archive.open('wb') as output:
            while chunk:=response.read(1024*1024):output.write(chunk)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=LOCK['cli_sha256']:
        raise RuntimeError('Контрольная сумма официального CLI не совпала')
    with tarfile.open(archive,'r:gz') as tar:
        member=tar.getmember('supabase')
        if not member.isfile():raise RuntimeError('Неверное содержимое архива CLI')
        source=tar.extractfile(member)
        if source is None:raise RuntimeError('Бинарник CLI отсутствует')
        (destination/'supabase').write_bytes(source.read())
    (destination/'supabase').chmod(0o755)
    return destination/'supabase'


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('destination');args=parser.parse_args()
    binary=install(args.destination)
    if path_file:=os.environ.get('GITHUB_PATH'):
        with open(path_file,'a') as output:output.write(str(binary.parent.resolve())+'\n')
    print('Официальный CLI 3.0.0 проверен по закреплённому SHA-256.')
