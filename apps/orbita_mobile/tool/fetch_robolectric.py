"""Prepare exact public Android test dependencies before running Robolectric.

No tests are skipped or replaced. Both official Maven endpoints publish the
pinned SHA-512 values; files enter the local Maven repository only after a full
streaming hash check. No application/server credentials are read.
"""
from pathlib import Path
import hashlib
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
HOSTS = ('https://repo.maven.apache.org/maven2/',
         'https://maven-central.storage-download.googleapis.com/maven2/')


def fetch(relative, destination, expected):
    if destination.is_file():
        with destination.open('rb') as existing:
            if hashlib.file_digest(existing, 'sha512').hexdigest() == expected:
                return
    destination.parent.mkdir(parents=True, exist_ok=True)
    for host in HOSTS:
        temp = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                temp = Path(output.name)
                request = urllib.request.Request(host+relative, headers={'User-Agent':'Orbita-CI-Dependencies/1'})
                with urllib.request.urlopen(request, timeout=60) as response:
                    digest = hashlib.sha512()
                    while chunk := response.read(1024*1024):
                        digest.update(chunk)
                        output.write(chunk)
                if digest.hexdigest() != expected:
                    raise ValueError('Dependency checksum mismatch; no unverified artifact installed')
            os.replace(temp, destination)
            return
        except ValueError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            # One bounded fallback to Google's official Maven Central mirror.
            continue
        finally:
            if temp is not None and temp.exists():
                temp.unlink()
    raise RuntimeError('Both official endpoints failed for '+relative)


def main():
    repository = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.home()/'.m2/repository'
    manifest = json.loads((ROOT/'robolectric_artifacts.json').read_text())
    for artifact in manifest['artifacts']:
        prefix = 'org/robolectric/{artifact}/{version}/{artifact}-{version}'.format(**artifact)
        # Install the JAR last: Robolectric treats its presence as a completed fetch.
        for suffix in ('pom','jar'):
            relative = prefix+'.'+suffix
            fetch(relative, repository/relative, artifact['sha512'][suffix])
        print('Verified Robolectric artifact:', artifact['artifact'], artifact['version'])


if __name__ == '__main__':
    main()
