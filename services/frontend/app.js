const $ = (id) => document.getElementById(id);

async function api(path, options = {}) {
  const res = await fetch(`/api${path}`, { headers: { "Content-Type": "application/json" }, ...options });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.message || res.statusText);
  return body;
}

async function loadInfo() {
  try {
    const info = await api("/info");
    $("greeting").textContent = info.greeting;
    $("pod").textContent = info.pod;
    $("node").textContent = info.node;
    $("version").textContent = info.version;
    $("identity").textContent = info.awsIdentity;
  } catch (err) {
    $("greeting").textContent = `API unavailable: ${err.message}`;
  }
}

async function loadMessages() {
  try {
    const messages = await api("/messages");
    $("messages").replaceChildren(...messages.map((m) => {
      const li = document.createElement("li");
      const who = document.createElement("strong");
      who.textContent = m.name;
      const text = document.createElement("p");
      text.textContent = m.message;
      const meta = document.createElement("small");
      meta.textContent = `${new Date(m.created).toLocaleString()} · saved by ${m.pod}`;
      li.append(who, text, meta);
      return li;
    }));
  } catch (err) {
    $("status").textContent = err.message;
  }
}

$("form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("/messages", {
      method: "POST",
      body: JSON.stringify({ name: $("name").value, message: $("message").value }),
    });
    $("message").value = "";
    $("status").textContent = "Thanks for signing!";
    await Promise.all([loadMessages(), loadInfo()]);
  } catch (err) {
    $("status").textContent = err.message;
  }
});

loadInfo();
loadMessages();
