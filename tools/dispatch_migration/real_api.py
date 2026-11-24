"""Real Auth + PostgREST, using ONLY owner-configured test account credentials.
No admin keys, generated JWTs, role changes, raw response/credential logging.
"""
from pathlib import Path
import base64
import json
import os
import urllib.error
import urllib.request
import uuid
from .policy import LOCK, require

class ApiRejected(RuntimeError):
    def __init__(self,status,code):
        self.status=status
        self.code=code
        super().__init__('API request rejected; raw response hidden')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        return None

class Accounts:
    def __init__(self,key,passenger,driver):
        require(isinstance(key,str) and key.startswith('sb_publishable_'),'Publishable client key required.')
        self.key=key
        self.credentials={'passenger':passenger,'driver':driver}
        require(all(isinstance(v,str) and v for pair in self.credentials.values() for v in pair),'Test account Secrets required before Apply.')
        require(passenger[0]!=driver[0],'Two different test accounts required.')
        self.sessions={}
        self.base='https://'+LOCK['project_ref']+'.supabase.co'
        self.http=urllib.request.build_opener(NoRedirect)

    @classmethod
    def from_environment(cls):
        require(os.environ.get('SUPABASE_TEST_PROJECT_REF')==LOCK['project_ref'],'Wrong API target.')
        return cls(os.environ.get('SUPABASE_TEST_PUBLISHABLE_KEY'),
          tuple(os.environ.get('ORBITA_DISPATCH_PASSENGER_'+v,'') for v in ('EMAIL','PASSWORD')),
          tuple(os.environ.get('ORBITA_DISPATCH_DRIVER_'+v,'') for v in ('EMAIL','PASSWORD')))

    def request(self,path,payload,role=None,*,no_content=False):
        headers={'apikey':self.key,'Content-Type':'application/json'}
        if role: headers['Authorization']='Bearer '+self.sessions[role]['token']
        req=urllib.request.Request(self.base+path,data=json.dumps(payload).encode(),headers=headers,method='POST')
        try:
            with self.http.open(req,timeout=12) as response:
                data=response.read(1024*1024+1)
                require(len(data)<=1024*1024,'API response too large.')
                if no_content:
                    require(response.status == 204 and not data, 'Local logout was not confirmed.')
                    return None
                return json.loads(data)
        except urllib.error.HTTPError as error:
            try:
                reply=json.loads(error.read(65536))
                code='ORB_DISPATCH_FORBIDDEN' if reply.get('message')=='ORB_DISPATCH_FORBIDDEN' else 'OTHER'
            except BaseException:
                code='OTHER'
            raise ApiRejected(error.code,code) from None
        except BaseException:
            raise RuntimeError('REAL_API_REQUEST_FAILED; raw response hidden; no automatic retry') from None

    @staticmethod
    def require_local_session(token):
        # Only require a session identifier for safe local logout. Roles are checked by PostgREST.
        try:
            _, segment, _ = token.split('.')
            claims = json.loads(base64.urlsafe_b64decode(segment + '=' * (-len(segment) % 4)))
            session_id = claims['session_id']
            parsed = uuid.UUID(session_id)
            require(parsed.int != 0 and str(parsed) == session_id, 'Invalid Auth session identifier.')
        except (AttributeError, IndexError, KeyError, TypeError, ValueError):
            require(False, 'The password grant did not return a scoped Auth session.')

    def authenticate_and_check_roles(self, *, require_local_sessions=False):
        for role,(email,password) in self.credentials.items():
            session=self.request('/auth/v1/token?grant_type=password',{'email':email,'password':password})
            token = session['access_token']
            if require_local_sessions:
                self.require_local_session(token)
            self.sessions[role] = {'token': token}
            self.sessions[role]['uid'] = session['user']['id']
            access=self.request('/rest/v1/rpc/orbita_get_access',{},role)
            require(access.get('status')=='active' and access.get('role')==role
              and access.get('user_id')==self.sessions[role]['uid'],'Test account server role mismatch.')
        require(self.sessions['passenger']['uid']!=self.sessions['driver']['uid'],'Separate test users required.')
        self.credentials.clear()

    def verify_preview_roles(self):
        require(not self.sessions, 'Recovery Auth requires a fresh client.')
        try:
            self.authenticate_and_check_roles(require_local_sessions=True)
        finally:
            logout_failed = False
            for role in self.sessions:
                try:
                    self.request('/auth/v1/logout?scope=local', {}, role, no_content=True)
                except Exception:
                    logout_failed = True
            self.sessions.clear()
            self.credentials.clear()
            require(not logout_failed, 'Recovery Auth local logout was not confirmed.')

    def rpc(self,role,action,payload=None):
        value=self.request('/rest/v1/rpc/orbita_dispatch',{'p_action':action,'p_payload':payload or {}},role)
        require(value.get('contract_version')==2 and value.get('user_id')==self.sessions[role]['uid']
                and value.get('role')==role,'APK v2 API contract mismatch.')
        return value

    def denied(self,role,action):
        # Authenticated wrong role must be rejected by the real RPC, not hidden UI.
        try:
            self.rpc(role,action)
        except ApiRejected as error:
            require(error.status==403 and error.code=='ORB_DISPATCH_FORBIDDEN','Role denial must be explicit HTTP 403.')
            return
        raise RuntimeError('ROLE_BOUNDARY_FAILED')

    def exercise(self,report):
        self.denied('passenger','driver_poll')
        self.denied('driver','passenger_poll')
        passenger=self.rpc('passenger','passenger_poll')
        driver=self.rpc('driver','driver_poll')
        require(passenger.get('order') is None and driver.get('order') is None and not driver.get('online'),
                'Synthetic test requires idle accounts; no existing trip is altered.')
        self.rpc('driver','online',{'online':True})
        request_id=str(uuid.uuid4())
        created=self.rpc('passenger','create',{'request_id':request_id,
          'pickup':{'address':'Тест Орбита 0.6.0, отправление','latitude':55,'longitude':82.43},
          'destination':{'address':'Тест Орбита 0.6.0, назначение','latitude':55.01,'longitude':82.44}})
        order=created['order']
        require(order['request_id']==request_id and order['status']=='created','Create not confirmed.')
        offered=self.rpc('driver','driver_poll')
        require(offered.get('offer') and offered['offer']['order_id']==order['id'],'Expected offer not confirmed.')
        accepted=self.rpc('driver','respond',{'offer_id':offered['offer']['id'],'response':'accept'})
        require(accepted['order']['id']==order['id'] and accepted['order']['status']=='accepted','Accept not confirmed.')
        require(self.rpc('passenger','passenger_poll')['order']['driver_id']==self.sessions['driver']['uid'],
                'Passenger confirmation failed.')
        for status in ('to_pickup','arrived','riding','completed'):
            current=self.rpc('driver','advance',{'order_id':order['id'],'status':status})
            require(current['order']['id']==order['id'] and current['order']['status']==status,'Trip step failed.')
        require(self.rpc('passenger','passenger_poll')['order']['status']=='completed','Completion not visible.')
        self.rpc('driver','online',{'online':False})
        Path(report).write_text(json.dumps({'status':'real_auth_postgrest_test_passed','project_ref':LOCK['project_ref'],
          'contract_version':2,'roles_checked':True,'created_accepted_completed':True,'driver_offline':True,
          'apk_commit':'d0cf7645f9083f5b1ba428131515cd916d84d3d7','physical_devices_tested':False},indent=2)+'\n')
