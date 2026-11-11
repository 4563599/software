import base64
import hashlib
import importlib.util
import tempfile
import unittest
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location('sync_server', Path(__file__).parents[1] / 'server' / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = server.Store(Path(self.temp.name) / 'test.sqlite3', hashlib.sha256(b'test-invite').hexdigest())
        self.owner = str(uuid.uuid4())
        self.encrypted = {'iv':base64.b64encode(b'x'*12).decode(), 'data':base64.b64encode(b'y'*32).decode()}
        self.profile = {'id':self.owner,'name':'test-vault','salt':base64.b64encode(b's'*16).decode(), 'check':self.encrypted,'auth':'a'*64}
        self.store.register(self.profile,'test-invite')

    def tearDown(self):
        self.temp.cleanup()

    def test_auth(self):
        self.assertEqual(self.store.login('test-vault','a'*64),self.owner)
        with self.assertRaises(server.ApiError):self.store.login('test-vault','wrong')
        self.assertNotIn('auth',self.store.profile('test-vault'))

    def test_enrollment_single_use(self):
        with self.assertRaises(server.ApiError):self.store.register(self.profile,'test-invite')
        with self.assertRaises(server.ApiError):self.store.register(self.profile,'wrong')

    def test_atomic_revision_and_retry(self):
        item={'id':str(uuid.uuid4()),'base':0,'envelope':self.encrypted}
        self.assertEqual(self.store.put(self.owner,item)['rev'],1)
        self.assertEqual(self.store.put(self.owner,item)['rev'],1)
        item['envelope']={**self.encrypted,'data':base64.b64encode(b'z'*32).decode()}
        with self.assertRaises(server.ApiError) as error:self.store.put(self.owner,item)
        self.assertEqual(error.exception.status,409)
        item['base']=1
        self.assertEqual(self.store.put(self.owner,item)['rev'],2)

    def test_isolation_and_validation(self):
        self.store.put(self.owner,{'id':str(uuid.uuid4()),'base':0,'envelope':self.encrypted})
        self.assertEqual(self.store.list_records(str(uuid.uuid4())),[])
        for value in ({}, {'iv':'x','data':'y'}, 'plaintext'):
            with self.assertRaises(server.ApiError):server.envelope(value)
        with self.assertRaises(server.ApiError):server.identifier('../../other')


if __name__=='__main__':unittest.main()
