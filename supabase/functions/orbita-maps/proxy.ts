const decimal = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

function coordinate(raw: string | null, limit: number): string {
  const text = raw?.trim() ?? '';
  if (text.length > 32 || !decimal.test(text)) throw Error('invalid');
  const value = Number(text);
  if (!Number.isFinite(value) || Math.abs(value) > limit) throw Error('invalid');
  return String(value);
}

export type MapPayload = 'tile' | 'places' | 'route';

/** Fixed upstreams and parameters. Never accepts a URL, API key, or redirect. */
export function upstream(input: URL): { url: URL; units: number; bytes: number; payload: MapPayload } {
  const path = input.searchParams.get('path') ?? '';
  const p = input.searchParams;
  let host = 'api.geoapify.com';
  const out = new URLSearchParams();
  let units = 1, bytes = 256 * 1024;
  let payload: MapPayload = 'places';
  if (/^\/v1\/tile\/(osm-carto|positron|dark-matter)\/\d{1,2}\/\d{1,7}\/\d{1,7}\.png$/.test(path)) {
    const parts = path.split('/');
    const z = Number(parts[4]), x = Number(parts[5]), y = Number(parts[6].slice(0,-4));
    if (z > 20 || x >= 2 ** z || y >= 2 ** z) throw Error('invalid');
    host = 'maps.geoapify.com'; bytes = 512 * 1024; payload = 'tile';
  } else if (path === '/v1/geocode/autocomplete') {
    const text = (p.get('text') ?? '').trim();
    if (text.length < 3 || text.length > 250) throw Error('invalid');
    out.set('text', text); out.set('filter','countrycode:ru'); out.set('bias','proximity:82.43,55');
    out.set('lang','ru'); out.set('limit','5'); out.set('format','json');
  } else if (path === '/v1/geocode/reverse') {
    out.set('lat',coordinate(p.get('lat'),90)); out.set('lon',coordinate(p.get('lon'),180));
    out.set('lang','ru'); out.set('limit','1'); out.set('format','json');
  } else if (path === '/v1/routing') {
    const pairs = (p.get('waypoints') ?? '').split('|');
    if (pairs.length !== 2) throw Error('invalid');
    const waypoints = pairs.map(pair => {
      const values = pair.split(',');
      if (values.length !== 2) throw Error('invalid');
      return [coordinate(values[0],90), coordinate(values[1],180)].join(',');
    });
    out.set('waypoints',waypoints.join('|')); out.set('mode','drive'); out.set('format','geojson');
    out.set('units','metric'); out.set('lang','ru'); units = 10; bytes = 1024 * 1024; payload = 'route';
  } else throw Error('invalid');
  const url = new URL(`https://${host}${path}`); url.search = out.toString();
  return {url,units,bytes,payload};
}
