import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { upstream } from './proxy.ts';
const plan=(path:string,params:Record<string,string>={})=>upstream(new URL('https://local.test/?'+new URLSearchParams({path,...params})));
test('fixed tile host/style/coordinates and no key forwarding',()=>{
  const p=plan('/v1/tile/osm-carto/16/47774/20701.png',{apiKey:'evil'});
  assert.equal(p.url.host,'maps.geoapify.com'); assert.equal(p.url.search,'');
  for(const path of [
    'https://evil.test',
    '/v1/tile/osm-carto/25/1/1.png',
    '/v1/tile/osm-carto/1/4/4.png',
    '/v1/tile/osm-carto/16/000047774/20701.png',
  ]) assert.throws(()=>plan(path));
});
test('local search parameters fixed and bounded',()=>{
  const p=plan('/v1/geocode/autocomplete',{text:'Пушкина 20',filter:'evil',apiKey:'evil'});
  assert.equal(p.url.searchParams.get('filter'),'countrycode:ru');
  assert.equal(p.url.searchParams.get('bias'),'proximity:82.43,55');
  assert.equal(p.url.searchParams.get('apiKey'),null);
  assert.throws(()=>plan('/v1/geocode/autocomplete',{text:'x'}));
});
test('reverse and route coordinates enforce latitude/longitude bounds',()=>{
  const p=plan('/v1/geocode/reverse',{lat:'+5.5e1',lon:'82.4300'});
  assert.equal(p.url.searchParams.get('lat'),'55');
  assert.equal(p.url.searchParams.get('lon'),'82.43');
  for (const lat of ['91', '', ' ', '0x37', 'Infinity']) {
    assert.throws(()=>plan('/v1/geocode/reverse',{lat,lon:'55'}));
  }
  const route = plan('/v1/routing',{waypoints:'55.0,82.43|+5.501e1,82.440'});
  assert.equal(route.units,10);
  assert.equal(route.url.searchParams.get('waypoints'),'55,82.43|55.01,82.44');
  for(const waypoints of ['55,82|NaN,82', '55,82|,82', '55,82|55, ', '55,82|55,181', '55,82|0x37,82']) {
    assert.throws(()=>plan('/v1/routing',{waypoints}));
  }
});
