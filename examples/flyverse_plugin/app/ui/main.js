// The page is a picture of the process behind it: it asks the app what is true
// every two seconds rather than keeping its own copy, so "stopped" is what the
// node says, not what a button last wrote.
const invoke = window.__TAURI__.core.invoke;

function text(id, value, cls) {
  const el = document.getElementById(id);
  el.textContent = value;
  if (cls) el.className = "value " + cls;
}

async function refresh() {
  try {
    const s = await invoke("status");
    document.title = s.app_name;
    document.getElementById("app-name").textContent = s.app_name;
    text("node", s.node);
    text("state", s.running ? "running" : "not running", "state " + (s.running ? "running" : "stopped"));
    text("joined", s.window_node || "no window answered");
    text("log", s.log);
    document.getElementById("stop").disabled = !s.running;
  } catch (error) {
    text("state", String(error), "state stopped");
  }
}

document.getElementById("open").addEventListener("click", () => invoke("open_studio"));
document.getElementById("stop").addEventListener("click", () => invoke("stop_node").then(refresh));
refresh();
setInterval(refresh, 2000);
