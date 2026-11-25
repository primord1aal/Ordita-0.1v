"""Read-only evidence for the single, proven pre-write Dispatch Apply failure."""

import re

from tools.orders_migration.admission import require


FAILED_APPLY_RUN_ID = '45287941746'
FAILED_APPLY_HEAD_SHA = '8816874afe3c4c8d963e94c48f693162706ab221'
FAILED_GUARDED_JOB_ID = 138089504572
RECOVERY_BASELINE_STATE_SHA256 = '05864c515ebd493d0d604fc5a57997e2dcd9d26b39a3552b3604ac66977b05eb'

_REPOSITORY = 'primord1aal/Ordita-0.1v'
_REPOSITORY_ID = 1443030751
_BRANCH = 'codex/orbita-e2e-test-060'
_WORKFLOW_PATH = '.github/workflows/orbita-dispatch-migration.yml'
DISPATCH_WORKFLOW_ID = 425221225
_ENVIRONMENT = 'orbita-mobile-test-orders-migrations'
_ENVIRONMENT_ID = 27244178038
_OWNER = 'primord1aal'
_OWNER_ID = 351526818
_LOCAL_TEST_ARTIFACT_ID = 14871838841
_TITLE = 'Орбита Dispatch: {operation} @ {sha}'
_APPLY_TITLE_PREFIX = 'Орбита Dispatch: apply @'
_MANUAL_TITLE = re.compile(r'Орбита Dispatch: (?:verify|preview|apply|inspect) @ ([a-f0-9]{40})')
_RUNNER_GROUP = '##[group]Run python3 -m tools.dispatch_migration.runner'
_FAILURE = ('DISPATCH_OPERATION_FAILED: stage=PREVIEW_OR_APPLY_EXECUTION; '
            'category=UNKNOWN_PRIVATE_ERROR; no raw errors; no automatic retry.')
_NO_APPLY = ('No files were found with the provided path: build/dispatch-public/apply.json. '
             'No artifacts will be uploaded.')
_NO_SERVER_TEST = (
    'No files were found with the provided path: build/dispatch-public/server-test.json',
    'build/dispatch-public/*error*.json',
    'build/dispatch-public/*inspection*.json. No artifacts will be uploaded.',
)
_TEST_ACCOUNT_KEYS = (
    'ORBITA_DISPATCH_PASSENGER_EMAIL',
    'ORBITA_DISPATCH_PASSENGER_PASSWORD',
    'ORBITA_DISPATCH_DRIVER_EMAIL',
    'ORBITA_DISPATCH_DRIVER_PASSWORD',
)
_LOG_TIMESTAMP = re.compile(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z (.*)$')
_ANSI_COLOR = re.compile(r'\x1b\[[0-9;]*m')


def _numeric_id(value):
    return type(value) is int and value > 0


def _same_id(value, expected):
    return _numeric_id(value) and value == expected


def _matches_project(repo):
    return (isinstance(repo, dict) and repo.get('full_name') == _REPOSITORY
            and _same_id(repo.get('id'), _REPOSITORY_ID))


def _validate_run_provenance(run, operation, expected_sha=None):
    sha = run.get('head_sha')
    require(isinstance(sha, str) and re.fullmatch('[a-f0-9]{40}', sha)
            and (expected_sha is None or sha == expected_sha)
            and run.get('display_title') == _TITLE.format(operation=operation, sha=sha)
            and run.get('event') == 'workflow_dispatch'
            and run.get('path') == _WORKFLOW_PATH
            and _same_id(run.get('workflow_id'), DISPATCH_WORKFLOW_ID)
            and run.get('head_branch') == _BRANCH
            and type(run.get('run_attempt')) is int and run['run_attempt'] == 1
            and _matches_project(run.get('repository'))
            and _matches_project(run.get('head_repository')),
            'Dispatch run provenance does not match.')


def _validate_failure_provenance(run):
    require(isinstance(run, dict) and _same_id(run.get('id'), int(FAILED_APPLY_RUN_ID)),
            'Expected the specific stopped Apply run.')
    _validate_run_provenance(run, 'apply', FAILED_APPLY_HEAD_SHA)
    require(run.get('status') == 'completed' and run.get('conclusion') == 'failure',
            'Original Apply failure provenance has changed.')


def validate_prior_attempts(runs, current_run_id, recovery_run_id=None, *, operation='apply', current_sha=None):
    """Keep the archive guard. Allow exactly one pinned exception in recovery mode."""
    require(isinstance(runs, (list, tuple)) and all(isinstance(run, dict) for run in runs),
            'Complete workflow history is required.')
    require((isinstance(current_run_id, str) and re.fullmatch('[1-9][0-9]{0,19}', current_run_id))
            or _numeric_id(current_run_id), 'Current run ID is invalid.')
    require(operation == 'apply' or (operation == 'preview' and recovery_run_id == FAILED_APPLY_RUN_ID),
            'This archive guard serves Apply and approved recovery Preview only.')
    if recovery_run_id is not None:
        require(isinstance(current_sha, str) and re.fullmatch('[a-f0-9]{40}', current_sha),
                'Recovery requires the exact current checkout SHA.')
    current_id = int(current_run_id)
    by_id = {}
    for run in runs:
        run_id = run.get('id')
        require(_numeric_id(run_id) and run_id not in by_id
                and isinstance(run.get('event'), str) and bool(run['event'])
                and isinstance(run.get('display_title'), str) and bool(run['display_title']),
                'Incomplete or duplicate workflow run history.')
        if recovery_run_id is not None and run_id < current_id:
            require(run['event'] in ('push', 'workflow_dispatch') and run.get('path') == _WORKFLOW_PATH
                    and _same_id(run.get('workflow_id'), DISPATCH_WORKFLOW_ID),
                    'Unrecognized historical workflow run.')
            if run['event'] == 'workflow_dispatch':
                title = _MANUAL_TITLE.fullmatch(run['display_title'])
                require(title is not None and title[1] == run.get('head_sha'),
                        'Cannot determine the mode of a historical manual run.')
        by_id[run_id] = run
    require(current_id in by_id, 'Current Dispatch run is missing from workflow history.')
    _validate_run_provenance(by_id[current_id], operation, current_sha)
    previous = [run for run_id, run in by_id.items()
                if run_id < current_id and run['event'] == 'workflow_dispatch'
                and run['display_title'].startswith(_APPLY_TITLE_PREFIX)]
    if recovery_run_id is None:
        require(not previous, 'Prior Apply attempt requires read-only investigation. No retry.')
        return
    require(recovery_run_id == FAILED_APPLY_RUN_ID and len(previous) == 1,
            'Recovery is limited to the one investigated Apply failure.')
    _validate_failure_provenance(previous[0])


def _complete_collection(payload, key):
    require(isinstance(payload, dict) and isinstance(payload.get(key), list)
            and type(payload.get('total_count')) is int
            and payload['total_count'] == len(payload[key])
            and all(isinstance(item, dict) for item in payload[key]),
            'Original run evidence is incomplete.')
    return payload[key]


def _validate_jobs(payload):
    expected = {
        138089026217: ('verify', 'success'),
        138089421973: ('entry', 'success'),
        FAILED_GUARDED_JOB_ID: ('guarded', 'failure'),
    }
    jobs = _complete_collection(payload, 'jobs')
    require(len(jobs) == len(expected), 'Unexpected original Apply jobs.')
    for job in jobs:
        job_id = job.get('id')
        require(_numeric_id(job_id) and job_id in expected
                and (job.get('name'), job.get('conclusion')) == expected.pop(job_id)
                and _same_id(job.get('run_id'), int(FAILED_APPLY_RUN_ID))
                and type(job.get('run_attempt')) is int and job['run_attempt'] == 1
                and job.get('head_sha') == FAILED_APPLY_HEAD_SHA and job.get('status') == 'completed',
                'Original Apply job provenance does not match.')
        if job_id != FAILED_GUARDED_JOB_ID:
            continue
        steps = job.get('steps')
        require(isinstance(steps, list) and all(isinstance(step, dict) for step in steps),
                'Original guarded job steps are missing.')
        checks = {
            3: ('Gate before database secrets', 'success'),
            4: ('Fixed PostgreSQL image', 'success'),
            5: ('Separately authorized operation', 'failure'),
        }
        for number, (name, conclusion) in checks.items():
            found = [step for step in steps if _same_id(step.get('number'), number)]
            require(len(found) == 1 and found[0].get('name') == name
                    and found[0].get('conclusion') == conclusion and found[0].get('status') == 'completed',
                    'Original guarded job step evidence has changed.')


def _validate_artifacts(payload):
    artifacts = _complete_collection(payload, 'artifacts')
    require(len(artifacts) == 1 and artifacts[0].get('name') == 'ORBITA-dispatch-local-tests'
            and _same_id(artifacts[0].get('id'), _LOCAL_TEST_ARTIFACT_ID)
            and artifacts[0].get('expired') is False, 'Unexpected historical Apply artifacts.')
    workflow_run = artifacts[0].get('workflow_run')
    require(isinstance(workflow_run, dict) and _same_id(workflow_run.get('id'), int(FAILED_APPLY_RUN_ID))
            and workflow_run.get('head_branch') == _BRANCH and workflow_run.get('head_sha') == FAILED_APPLY_HEAD_SHA
            and _same_id(workflow_run.get('repository_id'), _REPOSITORY_ID)
            and _same_id(workflow_run.get('head_repository_id'), _REPOSITORY_ID),
            'Historical artifact provenance does not match.')


def _validate_approval(approvals):
    require(isinstance(approvals, list) and len(approvals) == 1 and isinstance(approvals[0], dict),
            'Historical Apply approval is missing.')
    approval = approvals[0]
    user = approval.get('user')
    environments = approval.get('environments')
    require(approval.get('state') == 'approved' and isinstance(user, dict)
            and user.get('login') == _OWNER and _same_id(user.get('id'), _OWNER_ID)
            and isinstance(environments, list) and len(environments) == 1 and isinstance(environments[0], dict)
            and environments[0].get('name') == _ENVIRONMENT
            and _same_id(environments[0].get('id'), _ENVIRONMENT_ID),
            'Original owner approval does not match the protected Environment.')


def _validate_guarded_log(log):
    # Error text is allowlisted and constant. Never interpolate raw lines or values.
    require(isinstance(log, str) and 0 < len(log) <= 256 * 1024,
            'Original guarded log is missing or oversized.')
    lines = []
    for line in log.splitlines():
        match = _LOG_TIMESTAMP.fullmatch(_ANSI_COLOR.sub('', line))
        if match:
            lines.append(match[1].rstrip())
    require(lines.count(_RUNNER_GROUP) == 1 and lines.count(_FAILURE) == 1,
            'Original runner and pre-write failure markers are required.')
    group_start = lines.index(_RUNNER_GROUP)
    group_end = next((index for index in range(group_start + 1, len(lines))
                      if lines[index] == '##[endgroup]' or lines[index].startswith('##[group]')), len(lines))
    failure = lines.index(_FAILURE)
    require(group_end + 1 == failure and lines[group_end] == '##[endgroup]'
            and lines[failure + 1:failure + 2] == ['##[error]Process completed with exit code 1.'],
            'Original guarded runner failure is not in the expected step.')
    group = lines[group_start + 1:group_end]
    require(group.count('env:') == 1, 'Original guarded environment block is missing.')
    environment = group[group.index('env:') + 1:]
    for key in _TEST_ACCOUNT_KEYS:
        prefix = '  ' + key + ':'
        require([line for line in environment if line.startswith(prefix)] == [prefix],
                'Original test account inputs were not all shown empty.')
    after = lines[failure + 2:]
    require(after.count(_NO_APPLY) == 1 and after.count(_NO_SERVER_TEST[0]) == 1,
            'Original missing Apply and server-test output markers are required.')
    server_test_index = after.index(_NO_SERVER_TEST[0])
    require(after.index(_NO_APPLY) < server_test_index
            and tuple(after[server_test_index:server_test_index + len(_NO_SERVER_TEST)]) == _NO_SERVER_TEST,
            'Original guarded output paths do not match.')


def validate_failed_run(run, jobs, artifacts, approvals, *, log):
    """Verify the original failure happened before the executor could try a write."""
    _validate_failure_provenance(run)
    _validate_jobs(jobs)
    _validate_artifacts(artifacts)
    _validate_approval(approvals)
    _validate_guarded_log(log)
