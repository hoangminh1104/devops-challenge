const root = document.querySelector('main');
const refresh = document.querySelector('#refresh');
async function render() {
  refresh.disabled = true;
  root.textContent = 'Loading API health and database time…';
  try {
    const results = await Promise.all(['health', 'users'].map(async path => {
      const response = await fetch(`${API_BASE_URL}/${path}`, { cache: 'no-store', signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
      return response.json();
    }));
    const [health, users] = results;
    root.replaceChildren();
    for (const text of [
      `API: ${health.status}; release: ${health.release}`,
      `PostgreSQL: ${health.postgres.ok ? 'ready' : 'unavailable'}; Redis: ${health.redis.ok ? 'ready' : 'unavailable'}`,
      `Database time: ${users.time.now}`,
    ]) {
      const paragraph = document.createElement('p');
      paragraph.textContent = text;
      root.append(paragraph);
    }
  } catch (error) {
    root.textContent = `API unavailable: ${error.message}. Try Refresh.`;
  } finally { refresh.disabled = false; }
}
refresh.addEventListener('click', render);
render();
