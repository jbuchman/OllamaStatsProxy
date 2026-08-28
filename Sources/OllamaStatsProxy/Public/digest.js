const form = document.querySelector('#digest-form');
const modelSelect = form.elements.model;
const statusLine = document.querySelector('#status');

async function loadModels() {
  try {
    const response = await fetch('/stats');
    const stats = await response.json();
    const models = stats.installedModels || [];
    modelSelect.innerHTML = models.length
      ? models.map((model) => `<option value="${escapeHTML(model.name)}">${escapeHTML(model.name)}</option>`).join('')
      : '<option value="">No installed models found</option>';
  } catch {
    modelSelect.innerHTML = '<option value="">Could not load models</option>';
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = form.querySelector('button');
  button.disabled = true;
  statusLine.textContent = 'Researching and laying out your edition...';
  const values = new FormData(form);
  const payload = {
    query: values.get('query'), model: values.get('model'),
    title: values.get('title') || null, storyCount: Number(values.get('storyCount'))
  };
  try {
    const response = await fetch('/digests/pdf', {
      method: 'POST', headers: {'content-type':'application/json'}, body: JSON.stringify(payload)
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({error: `HTTP ${response.status}`}));
      throw new Error(error.error || 'Digest generation failed');
    }
    const url = URL.createObjectURL(await response.blob());
    const link = document.createElement('a');
    link.href = url; link.download = 'morning-digest.pdf'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
    statusLine.textContent = 'Your edition is ready.';
  } catch (error) {
    statusLine.textContent = error.message;
  } finally { button.disabled = false; }
});

function escapeHTML(value) {
  const node = document.createElement('span'); node.textContent = value; return node.innerHTML;
}

loadModels();
