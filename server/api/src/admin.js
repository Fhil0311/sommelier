// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The owner's stats page, served at /admin. The page itself holds no data: it asks for the owner's token and reads
// /v1/stats and /v1/failures with it. Kept in a JS string so the Worker needs no build step.

/** Only this page's own inline code, and requests back to the API itself. */
export const ADMIN_CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; " +
  "form-action 'none'; frame-ancestors 'none'; base-uri 'none'";

export const ADMIN_PAGE = String.raw`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Sommelier · статистика</title>
<style>
/* Owner's dashboard: summary tiles, then downloads/installs, players' reports, launch failures. */
:root {
  --bg: #f6f4f5; --panel: #ffffff; --fg: #1f1a1c; --muted: #6f6468; --line: #e6e0e2;
  --accent: #8e2742; --accent-soft: #f3dfe5; --good: #2f7d4f; --warn: #a76a00; --bad: #b3261e;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #171315; --panel: #211c1e; --fg: #f1ecee; --muted: #a8999f; --line: #342c30;
    --accent: #e0789a; --accent-soft: #3d2129; --good: #6cc48f; --warn: #e3a944; --bad: #f2867c; color-scheme: dark; }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 var(--sans); }
.wrap { max-width: 1180px; margin: 0 auto; padding: 24px 16px 64px; display: flex; flex-direction: column; gap: 20px; }
header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 20px; }
header h1 { font-size: 20px; margin: 0; font-weight: 650; letter-spacing: -0.01em; }
header h1 span { color: var(--accent); }
.spacer { flex: 1; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; background: var(--panel); }
.seg button { border: 0; background: none; color: var(--fg); padding: 6px 12px; font: inherit; cursor: pointer; }
.seg button + button { border-left: 1px solid var(--line); }
.seg button[aria-pressed="true"] { background: var(--accent); color: var(--panel); }
button.link { border: 0; background: none; color: var(--muted); cursor: pointer; font: inherit; padding: 4px; }
button:focus-visible, input:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.updated { color: var(--muted); font-size: 12px; }

.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; }
.tile { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; display: flex; flex-direction: column; gap: 2px; }
.tile .label { font-size: 12px; color: var(--muted); }
.tile .value { font-size: 28px; font-weight: 650; font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
.tile .sub { font-size: 12px; color: var(--muted); }

h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 12px 0 0; font-weight: 600; }
.grid { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 12px; }
.s2 { grid-column: span 2; } .s3 { grid-column: span 3; } .s4 { grid-column: span 4; }
@media (max-width: 860px) { .grid { grid-template-columns: minmax(0, 1fr); } .s2, .s3, .s4 { grid-column: auto; } }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; min-width: 0; display: flex; flex-direction: column; gap: 10px; }
.card h3 { font-size: 14px; margin: 0; font-weight: 600; }
.card .note { color: var(--muted); font-size: 12px; margin: 0; }
.wide { grid-column: 1 / -1; }
svg.chart { width: 100%; height: auto; display: block; }
svg.chart text { fill: var(--muted); font: 11px var(--sans); }
svg.chart .bar { fill: var(--accent); }
svg.chart .grid { stroke: var(--line); }

.scroll { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 600; color: var(--muted); font-size: 12px; }
td.num, th.num { text-align: right; }
td.title { white-space: normal; min-width: 160px; }
tr:last-child td { border-bottom: 0; }
tr.click { cursor: pointer; }
tr.click:hover td { background: var(--accent-soft); }
.meter { display: inline-block; height: 6px; border-radius: 3px; background: var(--accent); vertical-align: middle; margin-left: 8px; }
.pill { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px; border: 1px solid currentColor; }
.pill.good { color: var(--good); } .pill.warn { color: var(--warn); } .pill.bad { color: var(--bad); }
.empty { color: var(--muted); font-size: 13px; padding: 6px 0; }
code { font-family: var(--mono); font-size: 12px; }

.login { max-width: 380px; margin: 12vh auto 0; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 24px; display: flex; flex-direction: column; gap: 12px; }
.login h1 { margin: 0; font-size: 20px; }
.login p { margin: 0; color: var(--muted); }
.login input { font: 14px var(--mono); padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--fg); }
.login button { font: inherit; padding: 8px 12px; border: 0; border-radius: 8px; background: var(--accent); color: var(--panel); cursor: pointer; font-weight: 600; }
.error { color: var(--bad); font-size: 13px; margin: 0; }

dialog { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--fg); width: min(900px, calc(100vw - 32px)); max-height: 85vh; padding: 0; }
dialog::backdrop { background: rgba(0, 0, 0, 0.45); }
.dlg { padding: 18px 20px; display: flex; flex-direction: column; gap: 12px; }
.dlg header { justify-content: space-between; }
.dlg dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 0; }
.dlg dt { color: var(--muted); }
.dlg dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
pre.log { margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font: 12px/1.5 var(--mono); max-height: 50vh; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
.ann-form { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px 14px; }
.ann-form label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); min-width: 0; }
.ann-form .full { grid-column: 1 / -1; }
.ann-form input, .ann-form textarea, .ann-form select { font: 14px var(--sans); color: var(--fg); background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 7px 9px; min-width: 0; }
.ann-form textarea { min-height: 64px; resize: vertical; }
.ann-form .check { flex-direction: row; align-items: center; gap: 8px; color: var(--fg); font-size: 14px; }
.ann-actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.btn { font: inherit; padding: 8px 14px; border: 0; border-radius: 8px; background: var(--accent); color: var(--panel); cursor: pointer; font-weight: 600; }
.btn.quiet { background: none; border: 1px solid var(--line); color: var(--fg); font-weight: 500; padding: 4px 10px; }
.status-ok { color: var(--good); font-size: 13px; } .status-bad { color: var(--bad); font-size: 13px; }
@media (max-width: 860px) { .ann-form { grid-template-columns: minmax(0, 1fr); } }
.env { font-size: 12px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; padding: 3px 10px; border-radius: 999px; }
.env.production { background: var(--bad); color: var(--panel); }
.env.staging { background: var(--warn); color: var(--panel); }
.env.development { border: 1px solid var(--line); color: var(--muted); }
.row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.row input, .row select { font: 14px var(--sans); color: var(--fg); background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 7px 9px; min-width: 0; }
.preview { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; background: var(--bg); display: flex; flex-direction: column; gap: 4px; }
.preview.important { border-color: var(--warn); border-width: 2px; }
.preview strong { font-size: 14px; } .preview p { margin: 0; color: var(--muted); white-space: pre-wrap; }
.preview a { color: var(--accent); font-size: 13px; }
@media (prefers-reduced-motion: no-preference) { .tile, .card { transition: border-color .15s; } }
</style>
</head>
<body>
<div id="login" class="login" hidden>
  <h1>Статистика Sommelier</h1>
  <p>Токен владельца (ADMIN_TOKEN). Он хранится только в этом браузере.</p>
  <form id="loginForm"><div style="display:flex;flex-direction:column;gap:10px">
    <input id="token" type="password" autocomplete="current-password" placeholder="Токен" required>
    <button type="submit">Открыть</button>
    <p id="loginError" class="error" hidden></p>
  </div></form>
</div>

<div id="app" class="wrap" hidden>
  <header>
    <h1>Sommelier <span>статистика</span></h1>
    <span id="envBadge" class="env" hidden></span>
    <div class="seg" role="group" aria-label="Период">
      <button type="button" data-days="7">7 дней</button>
      <button type="button" data-days="30">30 дней</button>
      <button type="button" data-days="90">90 дней</button>
    </div>
    <div class="spacer"></div>
    <span id="updated" class="updated"></span>
    <button id="reload" type="button" class="link">Обновить</button>
    <button id="logout" type="button" class="link">Выйти</button>
  </header>

  <section class="tiles" id="tiles"></section>

  <h2>Скачивания и установки</h2>
  <div class="grid">
    <div class="card wide"><h3>Воронка</h3><p class="note">Скачали с сайта → установили (первый запуск) → остались → пользовались в последний день. * Удалённые и вернувшиеся видны только у тех, кто согласился делиться: молчит 30 дней — удалена, вышла на связь — вернулась. Для всех остальных это оценка по их доле.</p><div id="funnel"></div></div>
    <div class="card s3"><h3>Скачивания по дням</h3><div id="chartDownloads"></div></div>
    <div class="card s3"><h3>Новые установки по дням</h3><p class="note">Первый запуск Sommelier на Mac.</p><div id="chartNewInstalls"></div></div>
    <div class="card s3"><h3>Активные установки по дням</h3><p class="note">Сколько копий Sommelier проверили обновления за день.</p><div id="chartInstalls"></div></div>
    <div class="card s2"><h3>Откуда скачивают</h3><div id="bySource"></div></div>
    <div class="card s2"><h3>Страны</h3><div id="byCountry"></div></div>
    <div class="card s2"><h3>Версии у игроков</h3><p class="note" id="installsNote"></p><div id="installsByVersion"></div></div>
  </div>

  <h2>Отчёты игроков</h2>
  <div class="grid">
    <div class="card s3"><h3>Чем закончились игры</h3><div id="outcomes"></div></div>
    <div class="card s3"><h3>Маки игроков</h3><div id="chips"></div></div>
    <div class="card s3"><h3>Версии macOS</h3><p class="note">Игроков, по отчётам за период.</p><div id="macos"></div></div>
    <div class="card wide"><h3>Игры с наибольшим числом отчётов</h3><div class="scroll" id="topReported"></div></div>
    <div class="card wide"><h3>Какие настройки работают</h3><p class="note" id="manualNote"></p><div class="scroll" id="byBackend"></div></div>
  </div>

  <h2>Чем пользуются</h2>
  <p class="note">Только у тех, кто включил «Делиться тем, как идут игры»: раз в день, без имён. <span id="usagePlayers"></span></p>
  <div class="grid">
    <div class="card s2"><h3>Возвращаются</h3><div id="retention"></div></div>
    <div class="card s2"><h3>Подключённые магазины</h3><div id="usageStores"></div></div>
    <div class="card s2"><h3>Функции</h3><div id="usageFeatures"></div></div>
    <div class="card s2"><h3>Геймпады</h3><div id="usagePads"></div></div>
    <div class="card s2"><h3>От установки до первой игры</h3><div id="firstGame"></div></div>
  </div>

  <h2>Сбои запуска</h2>
  <div class="grid">
    <div class="card s2"><h3>По причинам</h3><p class="note">Причина — первое правило, которое узнало сбой. «unknown» значит, что правила ещё нет.</p><div id="bySignature"></div></div>
    <div class="card s4"><h3>Игры, которые падают у большинства</h3><div class="scroll" id="failingGames"></div></div>
    <div class="card wide"><h3>Кандидаты в рецепты</h3><p class="note">Игры, где один вариант графики падает, а другой работает минимум у трёх игроков. Подходящие добавьте в server/fixes/recipes.json и опубликуйте scripts/publish-recipes.sh.</p><div class="scroll" id="recipeCandidates"></div></div>
    <div class="card wide"><h3>Исправления, которые помогли</h3><p class="note">Игроки применили исправление, и игра запустилась минимум у трёх из них. Подходящие перенесите в server/recipes/review.py (готовый рецепт в последнем столбце) и опубликуйте.</p><div class="scroll" id="fixCandidates"></div></div>
    <div class="card wide"><h3>Как работают рецепты</h3><p class="note">Запуски с рецептом и без него (игрок его отменил). «Вредит» — сначала: такой рецепт стоит снять или поправить.</p><div class="scroll" id="recipeResults"></div></div>
    <div class="card wide"><h3>Нераспознанные сбои</h3><p class="note">Для них стоит написать правило в fixes.json. Нажмите на строку, чтобы открыть журнал.</p><div class="scroll" id="unrecognised"></div></div>
  </div>
  <h2>Сервер</h2>
  <section class="grid">
    <div class="card s2"><h3>Состояние</h3><div id="serverState"></div></div>
    <div class="card s4"><h3>Опубликованные списки</h3><p class="note">«Вернуть прошлую» ставит версию до последней публикации. Приложения получат её в течение нескольких часов.</p><div class="scroll" id="listState"></div><span id="listStatus"></span></div>
  </section>

  <h2>Шейдеры</h2>
  <section class="grid">
    <div class="card wide"><h3>Пакеты по играм</h3><p class="note">Загрузки игроков ждут, пока те же шейдеры пришлют минимум с двух адресов; потом их собирает scripts/merge-shaders.sh. «Удалить» убирает все пакеты игры, если в них попал плохой шейдер.</p><div class="scroll" id="shaderList"></div><span id="shaderStatus"></span></div>
  </section>

  <h2>Статусы игр</h2>
  <section class="grid">
    <div class="card wide"><h3>Проверено на наших Маках</h3><p class="note">Ваш статус важнее голосов игроков. Номер игры — как в магазине (Steam: число из адреса страницы).</p>
      <form id="verdictForm" class="row">
        <select id="vStore"><option value="steam">Steam</option><option value="epic">Epic</option><option value="gog">GOG</option><option value="ea">EA</option><option value="ubisoft">Ubisoft</option></select>
        <input id="vId" placeholder="Номер игры" required>
        <select id="vVerdict"><option value="works">Работает</option><option value="wontRun">Не запустится</option></select>
        <input id="vSteam" placeholder="Номер в Steam (для других магазинов)">
        <button class="btn" type="submit">Сохранить</button><span id="vStatus"></span>
      </form>
      <div class="scroll" id="verdictList"></div></div>
  </section>

  <h2>Данные игрока</h2>
  <section class="grid">
    <div class="card wide"><h3>Удалить по просьбе игрока</h3><p class="note">Удаляет все отчёты и сбои, отправленные с одной установки. Нужен номер установки игрока.</p>
      <form id="forgetForm" class="row"><input id="fClient" placeholder="Номер установки" required size="40"><button class="btn" type="submit">Удалить всё</button><span id="fStatus"></span></form></div>
  </section>

  <h2>Объявления игрокам</h2>
  <div class="grid">
    <div class="card wide"><h3>Сейчас опубликованы</h3><p class="note">Приложение проверяет список при запуске и раз в 3 часа. Закрытое игроком объявление ему больше не показывается.</p><div class="scroll" id="annList"></div></div>
    <div class="card wide"><h3>Новое объявление</h3>
      <form id="annForm" class="ann-form">
        <label>Заголовок по-русски<input id="annTitleRu" maxlength="120"></label>
        <label>Заголовок по-английски (обязательно)<input id="annTitleEn" maxlength="120" required></label>
        <label>Текст по-русски<textarea id="annBodyRu" maxlength="1000"></textarea></label>
        <label>Текст по-английски<textarea id="annBodyEn" maxlength="1000"></textarea></label>
        <label>Важность<select id="annLevel"><option value="info">Обычное</option><option value="important">Важное (оранжевая рамка, выше остальных)</option></select></label>
        <label>Показывать до (необязательно)<input id="annUntil" type="datetime-local"></label>
        <label>Ссылка (https, необязательно)<input id="annLink" type="url" placeholder="https://playsommelier.com/..."></label>
        <label>Подпись ссылки по-русски<input id="annLinkRu" maxlength="40" placeholder="Подробнее"></label>
        <label>Только версиям ниже (необязательно)<input id="annBelow" placeholder="например 0.3.0"></label>
        <label>Только владельцам игр (необязательно)<input id="annGames" placeholder="steam:271590, epic:Sage"></label>
        <label class="check full"><input id="annNotify" type="checkbox"> Ещё и уведомлением macOS (один раз)</label>
        <div class="full"><span class="note">Так увидят игроки (по-русски):</span><div id="annPreview" class="preview"></div></div>
        <div class="ann-actions full"><button class="btn" type="submit">Опубликовать</button><span id="annStatus"></span></div>
      </form>
    </div>
  </div>
</div>

<dialog id="detail"><div class="dlg" id="detailBody"></div></dialog>

<script>
(function () {
  "use strict";
  var KEY = "sommelier-admin-token", DAYS = "sommelier-admin-days";
  var store = { get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
                set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
                del: function (k) { try { localStorage.removeItem(k); } catch (e) {} } };
  // The token is the key to everything: kept only until the tab closes (and an older saved copy is dropped).
  var session = { get: function (k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } },
                  set: function (k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} },
                  del: function (k) { try { sessionStorage.removeItem(k); } catch (e) {} } };
  store.del(KEY);
  var token = session.get(KEY), days = Number(store.get(DAYS)) || 30;
  var $ = function (id) { return document.getElementById(id); };
  var nf = new Intl.NumberFormat("ru-RU");
  var OUTCOMES = { ran: ["Запустилась", "good"], crashed: ["Упала", "bad"], didNotStart: ["Не запустилась", "warn"] };
  var SOURCES = { site: "Сайт", update: "Обновление в приложении", other: "Другое" };
  var STORES = { steam: "Steam", epic: "Epic", gog: "GOG", ea: "EA", ubisoft: "Ubisoft", battlenet: "Battle.net" };

  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function n(v) { return nf.format(v || 0); }
  function api(path) {
    return fetch(path, { headers: { Authorization: "Bearer " + token } }).then(function (r) {
      if (r.status === 401) throw new Error("auth");
      if (!r.ok) throw new Error("http " + r.status);
      return r.json();
    });
  }

  function showLogin(message) {
    $("app").hidden = true; $("login").hidden = false;
    $("loginError").hidden = !message; $("loginError").textContent = message || "";
    $("token").focus();
  }
  $("loginForm").addEventListener("submit", function (e) {
    e.preventDefault(); token = $("token").value.trim(); session.set(KEY, token); load();
  });
  $("logout").addEventListener("click", function () { session.del(KEY); token = null; $("token").value = ""; showLogin(); });
  $("reload").addEventListener("click", function () { load(); });
  Array.prototype.forEach.call(document.querySelectorAll(".seg button"), function (b) {
    b.addEventListener("click", function () { days = Number(b.dataset.days); store.set(DAYS, String(days)); load(); });
  });

  var BACKENDS = { d3dMetal: "D3DMetal", dxmt: "DXMT", dxvk: "DXVK", wined3d: "WineD3D" };
  function loadCandidates() {
    api("/v1/recipes/candidates").then(function (r) {
      var list = r.candidates || [];
      if (!list.length) { $("recipeCandidates").innerHTML = '<p class="note">Пока нет: нужно больше отчётов.</p>'; return; }
      table($("recipeCandidates"), [["Игра"], ["Работает"], ["Игроков", "num"], ["Вместо"], ["Упало", "num"], ["Через окно «не запустилась»", "num"]],
        list.map(function (c) {
          var parts = c.game.split(":"), works = (c.backends || []).filter(function (b) { return b.backend === c.backend; })[0] || {};
          return '<tr><td class="title">' + gameName(c.title, parts[0], parts.slice(1).join(":")) + "</td><td>" + esc(BACKENDS[c.backend] || c.backend) +
            '</td><td class="num">' + n(c.players) + "</td><td>" + esc(BACKENDS[c.insteadOf] || c.insteadOf) +
            '</td><td class="num">' + n(c.failed) + " из " + n(c.of) + '</td><td class="num">' + n(works.retries) + "</td></tr>";
        }));
    }).catch(function (e) { $("recipeCandidates").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }

  function loadFixCandidates() {
    api("/v1/recipes/fix-candidates").then(function (r) {
      var list = r.candidates || [];
      if (!list.length) { $("fixCandidates").innerHTML = '<p class="note">Пока нет: нужно больше отчётов.</p>'; return; }
      table($("fixCandidates"), [["Игра"], ["Исправление"], ["Игроков", "num"], ["Запустилась", "num"], ["Рецепт"]],
        list.map(function (c) {
          var parts = c.game.split(":");
          return '<tr><td class="title">' + gameName(c.title, parts[0], parts.slice(1).join(":")) + "</td><td><code>" + esc(JSON.stringify(c.action)) +
            '</code></td><td class="num">' + n(c.players) + '</td><td class="num">' + n(c.ran) + " из " + n(c.of) +
            "</td><td><code>" + esc(JSON.stringify(c.recipe)) + "</code></td></tr>";
        }));
    }).catch(function (e) { $("fixCandidates").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }

  var VERDICTS = { hurts: "Вредит", helps: "Помогает", works: "Работает", unknown: "Мало данных" };
  function loadRecipeResults() {
    api("/v1/recipes/results").then(function (r) {
      var list = r.recipes || [];
      if (!list.length) { $("recipeResults").innerHTML = '<p class="note">Пока нет отчётов по играм с рецептами.</p>'; return; }
      var side = function (s) { return s.reports ? n(s.ran) + " из " + n(s.reports) + " (игроков: " + n(s.players) + ")" : "—"; };
      table($("recipeResults"), [["Игра"], ["Источник"], ["С рецептом запустилась"], ["Без рецепта запустилась"], ["Итог"]],
        list.map(function (g) {
          var parts = g.game.split(":");
          return '<tr><td class="title">' + gameName(g.title, parts[0], parts.slice(1).join(":")) + "</td><td>" + esc(g.source || "—") +
            "</td><td>" + side(g.with) + "</td><td>" + side(g.without) + "</td><td>" +
            (g.verdict === "hurts" ? "<b>" + VERDICTS.hurts + "</b>" : esc(VERDICTS[g.verdict] || g.verdict)) + "</td></tr>";
        }));
    }).catch(function (e) { $("recipeResults").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }

  function load() {
    if (!token) return showLogin();
    Array.prototype.forEach.call(document.querySelectorAll(".seg button"), function (b) { b.setAttribute("aria-pressed", String(Number(b.dataset.days) === days)); });
    Promise.all([api("/v1/stats?days=" + days), api("/v1/failures?days=" + Math.min(days, 180))]).then(function (r) {
      $("login").hidden = true; $("app").hidden = false;
      render(r[0], r[1]);
      loadAnnouncements(); loadStatus(); loadShaders(); loadVerdicts();
      loadCandidates(); loadFixCandidates(); loadRecipeResults();
      $("updated").textContent = "Обновлено в " + new Date().toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
    }).catch(function (e) {
      if (e.message === "auth") { session.del(KEY); token = null; showLogin("Токен не подошёл. После 20 неверных попыток адрес блокируется до завтра."); }
      else { $("updated").textContent = "Не удалось загрузить: " + e.message; }
    });
  }

  function tile(label, value, sub) {
    return '<div class="tile"><span class="label">' + esc(label) + '</span><span class="value">' + value + '</span><span class="sub">' + esc(sub || "") + "</span></div>";
  }

  function daysRange(since) {
    var out = [], d = new Date(since + "T00:00:00Z"), end = new Date();
    while (d <= end) { out.push(d.toISOString().slice(0, 10)); d = new Date(d.getTime() + 86400000); }
    return out;
  }

  function chart(el, list, since) {
    var map = {}; list.forEach(function (r) { map[r.day] = r.count; });
    var all = daysRange(since), values = all.map(function (d) { return map[d] || 0; });
    var max = Math.max.apply(null, values.concat([1]));
    var nice = max <= 5 ? 5 : Math.ceil(max / 5) * 5;
    var W = 600, H = 170, L = 32, B = 20, T = 8, w = (W - L) / values.length;
    var s = '<svg class="chart" viewBox="0 0 ' + W + " " + H + '" role="img">';
    [0, nice / 2, nice].forEach(function (v) {
      var y = H - B - (H - B - T) * v / nice;
      s += '<line class="grid" x1="' + L + '" x2="' + W + '" y1="' + y + '" y2="' + y + '"/>';
      s += '<text x="' + (L - 6) + '" y="' + (y + 4) + '" text-anchor="end">' + n(v) + "</text>";
    });
    values.forEach(function (v, i) {
      var h = (H - B - T) * v / nice;
      if (v > 0) s += '<rect class="bar" x="' + (L + i * w + w * 0.15) + '" y="' + (H - B - h) + '" width="' + Math.max(w * 0.7, 1) + '" height="' + h + '"><title>' + all[i] + ": " + v + "</title></rect>";
    });
    [0, values.length - 1].forEach(function (i, k) {
      var label = all[i].slice(8, 10) + "." + all[i].slice(5, 7);
      s += '<text x="' + (k ? W : L) + '" y="' + (H - 4) + '" text-anchor="' + (k ? "end" : "start") + '">' + label + "</text>";
    });
    el.innerHTML = s + "</svg>";
  }

  function bars(el, obj, names) {
    var entries = Object.keys(obj).map(function (k) { return [k, obj[k]]; });
    if (!entries.length) { el.innerHTML = '<div class="empty">Пока нет данных</div>'; return; }
    var max = Math.max.apply(null, entries.map(function (e) { return e[1]; }));
    el.innerHTML = "<table><tbody>" + entries.slice(0, 12).map(function (e) {
      return "<tr><td>" + esc(names && names[e[0]] ? names[e[0]] : e[0]) + '</td><td class="num">' + n(e[1]) +
        '<span class="meter" style="width:' + Math.round(60 * e[1] / max) + 'px"></span></td></tr>';
    }).join("") + "</tbody></table>";
  }

  function share(part, whole) { return whole ? Math.round(100 * part / whole) + "%" : "—"; }

  function renderFunnel(stats) {
    var site = (stats.downloads.bySource || {}).site || 0, inst = stats.installs.total;
    var act = stats.activeInstalls.byDay, active = act.length ? act[act.length - 1].count : 0;
    table($("funnel"), [["Шаг"], ["Сколько", "num"], ["От предыдущего", "num"]], [
      '<tr><td>Скачали с сайта</td><td class="num">' + n(site) + '</td><td class="num">—</td></tr>',
      '<tr><td>Установили</td><td class="num">' + n(inst) + '</td><td class="num">' + share(inst, site) + "</td></tr>",
      '<tr><td>Остались* (у делящихся)</td><td class="num">' + share(stats.installs.installedNow, stats.installs.tracked) + '</td><td class="num">≈ ' + n(Math.round(stats.installs.allTime * (stats.installs.tracked ? stats.installs.installedNow / stats.installs.tracked : 0))) + " из всех установок</td></tr>",
      '<tr><td>Пользовались в последний день</td><td class="num">' + n(active) + '</td><td class="num">' + share(active, stats.installs.allTime) + " от всех установок</td></tr>"]);
  }

  function renderUsage(u) {
    u = u || { players: 0, stores: {}, features: {}, pads: {}, firstGame: {}, retention: { week: {}, month: {} } };
    $("usagePlayers").textContent = "Игроков за период: " + n(u.players) + ".";
    var r = u.retention;
    table($("retention"), [["Через"], ["Вернулись", "num"]], [
      '<tr><td>Неделю</td><td class="num">' + (r.week.players ? share(r.week.back, r.week.players) + " из " + n(r.week.players) : "—") + "</td></tr>",
      '<tr><td>Месяц</td><td class="num">' + (r.month.players ? share(r.month.back, r.month.players) + " из " + n(r.month.players) : "—") + "</td></tr>"]);
    var stores = {}; Object.keys(u.stores).forEach(function (k) { stores[STORES[k] || k] = u.stores[k]; });
    if (u.noStore) stores["Ни одного"] = u.noStore;
    bars($("usageStores"), stores);
    var f = u.features;
    bars($("usageFeatures"), u.players ? { "Режим геймпада": f.controllerMode, "Клипы": f.clips, "Счётчик кадров": f.counter } : {});
    var pads = {}; var PADS = { xbox: "Xbox", playStation: "PlayStation", other: "Другие" };
    Object.keys(u.pads).forEach(function (k) { pads[PADS[k] || k] = u.pads[k]; });
    bars($("usagePads"), pads);
    var g = u.firstGame;
    $("firstGame").innerHTML = g.players
      ? "<table><tbody><tr><td>Медиана</td><td class=\"num\">" + n(g.median) + " мин</td></tr><tr><td>В первый час</td><td class=\"num\">" +
        share(g.withinHour, g.players) + "</td></tr><tr><td>Игроков</td><td class=\"num\">" + n(g.players) + "</td></tr></tbody></table>"
      : '<div class="empty">Пока нет данных</div>';
  }

  function table(el, head, rows) {
    if (!rows.length) { el.innerHTML = '<div class="empty">Пока нет данных</div>'; return; }
    el.innerHTML = "<table><thead><tr>" + head.map(function (h) { return '<th class="' + (h[1] || "") + '">' + esc(h[0]) + "</th>"; }).join("") +
      "</tr></thead><tbody>" + rows.join("") + "</tbody></table>";
  }

  function countryNames(obj) {
    var out = {}, dn = null;
    try { dn = new Intl.DisplayNames(["ru"], { type: "region" }); } catch (e) {}
    Object.keys(obj).forEach(function (k) { try { out[k] = dn && /^[A-Z]{2}$/.test(k) ? dn.of(k) : k; } catch (e) { out[k] = k; } });
    return out;
  }

  function gameName(title, store, id) { return esc(title || ((STORES[store] || store) + " " + id)); }

  function render(stats, fails) {
    var outcomes = stats.reports.byOutcome || {};
    var ran = outcomes.ran || 0, total = stats.reports.recent || 0;
    var installs = stats.activeInstalls.byDay, lastInstalls = installs.length ? installs[installs.length - 1].count : 0;
    $("tiles").innerHTML =
      tile("Скачивания", n(stats.downloads.total), "за " + days + " дн.") +
      tile("Установки", n(stats.installs.allTime), "всего; за " + days + " дн.: " + n(stats.installs.total)) +
      tile("Установлено сейчас*", n(stats.installs.installedNow), "из " + n(stats.installs.tracked) + " делящихся; удалили: " + n(stats.installs.uninstalled) + ", вернулись за " + days + " дн.: " + n(stats.installs.returned)) +
      tile("Активные установки", n(lastInstalls), stats.activeInstalls.latestDay ? "за " + stats.activeInstalls.latestDay.split("-").reverse().join(".") : "пока нет проверок") +
      tile("Отчёты игроков", n(total), total ? Math.round(100 * ran / total) + "% игр запустились" : "за " + days + " дн.") +
      tile("Сбои запуска", n(fails.total), fails.total ? n((fails.bySignature.filter(function (s) { return s.signature === "unknown"; })[0] || {}).count || 0) + " нераспознанных" : "за " + Math.min(days, 180) + " дн.") +
      tile("Игр в каталоге", n(stats.catalogue.games), "всего");

    chart($("chartDownloads"), stats.downloads.byDay, stats.since);
    chart($("chartInstalls"), installs, stats.since);
    chart($("chartNewInstalls"), stats.installs.byDay, stats.since);
    bars($("bySource"), stats.downloads.bySource, SOURCES);
    bars($("byCountry"), stats.downloads.byCountry, countryNames(stats.downloads.byCountry));
    $("installsNote").textContent = stats.activeInstalls.latestDay ? "По последнему дню с проверками." : "";
    bars($("installsByVersion"), stats.activeInstalls.byVersion);

    var named = {}; Object.keys(outcomes).forEach(function (k) { named[(OUTCOMES[k] || [k])[0]] = outcomes[k]; });
    bars($("outcomes"), named);
    bars($("chips"), stats.reports.byChip || {});
    bars($("macos"), stats.reports.byMacOS || {});
    renderFunnel(stats);
    renderUsage(stats.usage);
    table($("topReported"), [["Игра"], ["Отчётов", "num"], ["Запустилась", "num"], ["Средний FPS", "num"]],
      (stats.reports.topGames || []).map(function (g) {
        var share = g.reports ? Math.round(100 * g.ran / g.reports) : 0;
        var cls = share >= 80 ? "good" : share >= 40 ? "warn" : "bad";
        return '<tr><td class="title">' + esc(g.title || g.game) + '</td><td class="num">' + n(g.reports) + '</td><td class="num"><span class="pill ' + cls + '">' + share + "%</span></td><td class=\"num\">" + (g.fps ? n(g.fps) : "—") + "</td></tr>";
      }));

    var st = stats.settings || { byGameBackend: [], manual: 0, withChoice: 0 };
    $("manualNote").textContent = st.withChoice
      ? "Графику выбирали вручную в " + Math.round(100 * st.manual / st.withChoice) + "% отчётов. Если у игры её часто меняют вручную, автоматический выбор для неё ошибается."
      : (st.byGameBackend.length ? "Доля ручного выбора графики появится, когда придут отчёты из новых версий приложения." : "Появится, когда придут отчёты с настройками.");
    var BACKENDS = { dxmt: "DXMT", d3dMetal: "D3DMetal", dxvk: "DXVK", wined3d: "WineD3D", auto: "Автоматически", native: "Для Mac" };
    var previous = null;
    table($("byBackend"), [["Игра"], ["Графика"], ["Отчётов", "num"], ["Запустилась", "num"], ["Выбрали вручную", "num"], ["Средний FPS", "num"]],
      st.byGameBackend.map(function (r) {
        var share = r.reports ? Math.round(100 * r.ran / r.reports) : 0;
        var cls = share >= 80 ? "good" : share >= 40 ? "warn" : "bad";
        var name = r.game === previous ? "" : esc(r.title || r.game); previous = r.game;
        return '<tr><td class="title">' + name + "</td><td>" + esc(BACKENDS[r.backend] || r.backend) + '</td><td class="num">' + n(r.reports) +
          '</td><td class="num"><span class="pill ' + cls + '">' + share + '%</span></td><td class="num">' + n(r.manual) + '</td><td class="num">' + (r.fps ? n(r.fps) : "—") + "</td></tr>";
      }));

    bars($("bySignature"), fails.bySignature.reduce(function (o, s) { o[s.signature] = s.count; return o; }, {}));
    table($("failingGames"), [["Игра"], ["Игроков", "num"], ["Сбоев", "num"], ["Причины"]],
      fails.topGames.map(function (g) {
        return '<tr><td class="title">' + gameName(g.title, g.store, g.id) + '</td><td class="num">' + n(g.players) + '</td><td class="num">' + n(g.count) + "</td><td><code>" + esc(g.signatures) + "</code></td></tr>";
      }));
    table($("unrecognised"), [["Когда"], ["Игра"], ["Магазин"], ["Графика"], ["Движок"], ["Код выхода", "num"], ["Проработала", "num"]],
      fails.unrecognised.map(function (f) {
        return '<tr class="click" tabindex="0" data-id="' + f.id + '"><td>' + new Date(f.created_at).toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) +
          '</td><td class="title">' + gameName(f.title, f.store, f.game_id) + "</td><td>" + esc(STORES[f.store] || f.store) + "</td><td>" + esc(f.backend || "—") + "</td><td>" + esc(f.engine || "—") +
          '</td><td class="num">' + (f.exit_code == null ? "—" : esc(f.exit_code)) + '</td><td class="num">' + (f.seconds_running == null ? "—" : esc(f.seconds_running) + " с") + "</td></tr>";
      }));
    Array.prototype.forEach.call(document.querySelectorAll("#unrecognised tr.click"), function (tr) {
      var open = function () { showFailure(tr.dataset.id); };
      tr.addEventListener("click", open);
      tr.addEventListener("keydown", function (e) { if (e.key === "Enter") open(); });
    });
  }

  function showFailure(id) {
    api("/v1/failures/" + encodeURIComponent(id)).then(function (f) {
      var d = f.diagnostics || {};
      var rows = [["Игра", gameName(f.title, f.store, f.game_id)], ["Магазин", esc(STORES[f.store] || f.store) + " · <code>" + esc(f.game_id) + "</code>"],
        ["Sommelier", esc(f.app_version || "—") + ", движок " + esc(f.engine || "—")], ["Графика", esc(f.backend || "—")],
        ["Mac", esc([f.chip, f.macos].filter(Boolean).join(", ") || "—")],
        ["Что произошло", "код выхода " + esc(f.exit_code == null ? "—" : f.exit_code) + ", через " + esc(f.seconds_running == null ? "—" : f.seconds_running) + " с"],
        ["Распознано", f.matched.length ? "<code>" + esc(f.matched.join(", ")) + "</code>" : "ничего"]];
      var logs = [["Журнал запуска", d.logTail], ["Журнал Steam", d.steamLogTail], ["Отчёт о сбое macOS", d.crashReport]].filter(function (l) { return l[1]; });
      $("detailBody").innerHTML = '<header><h3 style="margin:0">Сбой №' + esc(f.id) + '</h3><button type="button" class="link" id="closeDetail">Закрыть</button></header>' +
        "<dl>" + rows.map(function (r) { return "<dt>" + r[0] + "</dt><dd>" + r[1] + "</dd>"; }).join("") + "</dl>" +
        logs.map(function (l) { return '<h3 style="margin:4px 0 0;font-size:13px">' + l[0] + '</h3><pre class="log">' + esc(l[1]) + "</pre>"; }).join("");
      $("closeDetail").addEventListener("click", function () { $("detail").close(); });
      $("detail").showModal();
    }).catch(function () {});
  }

  // MARK: Announcements
  var announcements = [], annBase = "";
  var LEVELS = { info: "Обычное", important: "Важное" };
  function loadAnnouncements() {
    fetch("/v1/announcements.json", { cache: "no-store" }).then(function (r) { annBase = r.headers.get("ETag") || ""; return r.json(); }).then(function (list) {
      announcements = list.announcements || []; renderAnnouncements();
    }).catch(function () {});
  }
  function renderAnnouncements() {
    table($("annList"), [["Заголовок"], ["Важность"], ["До"], ["Кому"], ["Уведомление"], [""]],
      announcements.map(function (a, i) {
        var who = [a.belowApp ? "версии ниже " + a.belowApp : "", a.games && a.games.length ? a.games.length + " игр" : ""].filter(Boolean).join(", ") || "всем";
        return '<tr><td class="title">' + esc(a.title.ru || a.title.en) + "</td><td>" + esc(LEVELS[a.level] || a.level) + "</td><td>" +
          (a.until ? esc(new Date(a.until).toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })) : "—") +
          "</td><td>" + esc(who) + "</td><td>" + (a.notify ? "да" : "нет") + '</td><td><button type="button" class="btn quiet" data-remove="' + i + '">Убрать</button></td></tr>';
      }));
    Array.prototype.forEach.call(document.querySelectorAll("[data-remove]"), function (b) {
      b.addEventListener("click", function () {
        var a = announcements[Number(b.dataset.remove)];
        if (!window.confirm("Убрать объявление «" + (a.title.ru || a.title.en) + "»? Игроки перестанут его видеть.")) return;
        var next = announcements.slice(); next.splice(Number(b.dataset.remove), 1); publish(next, "Убрано");
      });
    });
  }
  function publish(list, done) {
    $("annStatus").className = ""; $("annStatus").textContent = "Публикую…";
    return fetch("/v1/announcements.json", { method: "PUT", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json", "X-Sommelier-Base": annBase },
      body: JSON.stringify({ version: 1, announcements: list }) }).then(function (r) {
      if (r.status === 409) { loadAnnouncements(); throw new Error("список изменился в другой вкладке или скриптом. Я загрузил свежий, повторите."); }
      return r.json().then(function (body) {
        if (!r.ok) throw new Error((body.problems || [body.error]).join("; "));
        announcements = list; renderAnnouncements(); loadAnnouncements(); loadStatus();
        $("annStatus").className = "status-ok"; $("annStatus").textContent = done;
        return true;
      });
    }).catch(function (e) { $("annStatus").className = "status-bad"; $("annStatus").textContent = "Не опубликовано: " + e.message; return false; });
  }
  $("annForm").addEventListener("submit", function (e) {
    e.preventDefault();
    var v = function (id) { return $(id).value.trim(); };
    var a = { id: "a-" + Date.now().toString(36), level: $("annLevel").value, title: { en: v("annTitleEn") } };
    if (v("annTitleRu")) a.title.ru = v("annTitleRu");
    if (v("annBodyEn") || v("annBodyRu")) { a.body = { en: v("annBodyEn") || v("annBodyRu") }; if (v("annBodyRu")) a.body.ru = v("annBodyRu"); }
    if (v("annLink")) { a.link = { url: v("annLink") }; if (v("annLinkRu")) a.link.label = { en: "Learn more", ru: v("annLinkRu") }; }
    if (v("annUntil")) a.until = new Date(v("annUntil")).toISOString();
    if (v("annBelow")) a.belowApp = v("annBelow");
    if (v("annGames")) a.games = v("annGames").split(/[\s,]+/).filter(Boolean);
    if ($("annNotify").checked) a.notify = true;
    publish(announcements.concat([a]), "Опубликовано. Игроки увидят его в течение 3 часов или при запуске Sommelier.").then(function (ok) { if (ok) $("annForm").reset(); });
  });

  function preview() {
    var v = function (id) { return $(id).value.trim(); };
    var title = v("annTitleRu") || v("annTitleEn"), body = v("annBodyRu") || v("annBodyEn");
    var box = $("annPreview");
    box.className = "preview" + ($("annLevel").value === "important" ? " important" : "");
    box.innerHTML = title ? "<strong>" + esc(title) + "</strong>" + (body ? "<p>" + esc(body) + "</p>" : "") +
      (v("annLink") ? '<a href="#" tabindex="-1">' + esc(v("annLinkRu") || "Подробнее") + "</a>" : "") : '<span class="note">Заполните заголовок</span>';
  }
  Array.prototype.forEach.call($("annForm").querySelectorAll("input, textarea, select"), function (el) { el.addEventListener("input", preview); });
  $("annForm").addEventListener("reset", function () { setTimeout(preview, 0); });
  preview();

  function say(id, ok, text) { $(id).className = ok ? "status-ok" : "status-bad"; $(id).textContent = text; }
  function send(method, path, body) {
    var headers = { Authorization: "Bearer " + token };
    if (body) headers["Content-Type"] = "application/json";
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (b) { if (!r.ok) throw new Error(b.error || ("http " + r.status)); return b; });
    });
  }
  function when(iso) { return iso ? new Date(iso).toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit" }) : "—"; }

  var ENVS = { production: "Боевой сервер", staging: "Тестовый сервер", development: "На этом Mac" };
  var LIST_NAMES = { "fixes.json": "Исправления сбоев", "recipes.json": "Рецепты", "announcements.json": "Объявления", "saves.json": "Папки сохранений" };
  function loadStatus() {
    api("/v1/admin/status").then(function (s) {
      $("envBadge").hidden = false; $("envBadge").className = "env " + s.environment; $("envBadge").textContent = ENVS[s.environment] || s.environment;
      document.title = (ENVS[s.environment] || s.environment) + " · Sommelier";
      var secrets = Object.keys(s.secrets).map(function (k) { return '<span class="pill ' + (s.secrets[k] ? "good" : "bad") + '">' + esc(k) + "</span>"; }).join(" ");
      $("serverState").innerHTML = '<div class="dlg" style="padding:0"><dl>' +
        "<dt>Последний бэкап</dt><dd>" + (s.backup ? esc(s.backup) + " (копий: " + n(s.backups) + ")" : '<span class="pill warn">ещё не было</span>') + "</dd>" +
        "<dt>Секреты</dt><dd>" + secrets + "</dd>" +
        "<dt>Game Porting Toolkit, macOS 27+</dt><dd>" + toolkitState(s.toolkit, "download") + ' <button type="button" class="btn quiet" data-toolkit="download">Поменять ссылку</button></dd>' +
        "<dt>Game Porting Toolkit, macOS 26 и старше</dt><dd>" + toolkitState(s.toolkit, "legacy") + ' <button type="button" class="btn quiet" data-toolkit="legacy">Поменять ссылку</button></dd>' +
        "<dt>Сервис шейдеров</dt><dd>" + (s.decanter ? '<span class="pill good">подключён</span>' : '<span class="pill bad">не подключён</span>') + "</dd>" +
        "<dt>Отчётов</dt><dd>" + n(s.rows.reports) + "</dd><dt>Сбоев</dt><dd>" + n(s.rows.failures) + "</dd><dt>Игр в каталоге</dt><dd>" + n(s.rows.games) + "</dd></dl></div>";
      table($("listState"), [["Список"], ["Опубликован"], ["Размер", "num"], ["Прошлых версий", "num"], [""]],
        s.lists.map(function (l) {
          return '<tr><td>' + esc(LIST_NAMES[l.name] || l.name) + "</td><td>" + when(l.published) + '</td><td class="num">' + n(Math.round(l.bytes / 1024)) + " КБ</td>" +
            '<td class="num">' + n(l.history) + '</td><td>' + (l.history ? '<button type="button" class="btn quiet" data-rollback="' + esc(l.name) + '">Вернуть прошлую</button>' : "") + "</td></tr>";
        }));
      Array.prototype.forEach.call(document.querySelectorAll("[data-toolkit]"), function (b) {
        b.addEventListener("click", function () {
          var link = window.prompt("Ссылка на .dmg со страницы загрузок Apple (правая кнопка → Скопировать ссылку):");
          if (!link) return;
          var body = { version: 1 }; body[b.dataset.toolkit] = link.trim();
          send("PUT", "/v1/toolkit.json", body).then(function () { say("listStatus", true, "Ссылка на Game Porting Toolkit сохранена"); loadStatus(); })
            .catch(function (e) { say("listStatus", false, "Ссылка не сохранена: " + e.message); });
        });
      });
      Array.prototype.forEach.call(document.querySelectorAll("[data-rollback]"), function (b) {
        b.addEventListener("click", function () {
          var name = b.dataset.rollback;
          if (!window.confirm("Вернуть прошлую версию списка «" + (LIST_NAMES[name] || name) + "»? Текущая будет заменена.")) return;
          send("POST", "/v1/" + name + "/rollback").then(function () { say("listStatus", true, "Возвращено"); loadStatus(); if (name === "announcements.json") loadAnnouncements(); })
            .catch(function (e) { say("listStatus", false, "Не вышло: " + e.message); });
        });
      });
    }).catch(function (e) { $("serverState").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }

  function toolkitState(t, key) {
    t = t || {};
    var file = t[key] ? esc(decodeURIComponent(t[key].split("/").pop())) : "встроенная в приложение";
    var changed = key === "download" && t.watch && t.watch.changedAt
      ? ' <span class="pill warn">Apple обновила страницу ' + when(t.watch.changedAt) + ": " + esc((t.watch.versions || []).join(", ")) + ". Проверьте ссылку</span>" : "";
    return file + changed;
  }

  function loadShaders() {
    api("/v1/admin/shaders").then(function (r) {
      table($("shaderList"), [["Игра"], ["Пакетов", "num"], ["Размер", "num"], ["Обновлён"], ["Ждут загрузок", "num"], ["С адресов", "num"], [""]],
        (r.games || []).map(function (g) {
          return '<tr><td class="title">' + gameName("", g.store, g.game) + '</td><td class="num">' + n(g.packs) + '</td><td class="num">' + n(Math.round(g.bytes / 1024)) + " КБ</td><td>" +
            when(g.updated) + '</td><td class="num">' + n(g.waiting) + '</td><td class="num">' + n(g.addresses) + "</td><td>" +
            (g.packs ? '<button type="button" class="btn quiet" data-purge="' + esc(g.store + "/" + g.game) + '">Удалить</button>' : "") + "</td></tr>";
        }));
      Array.prototype.forEach.call(document.querySelectorAll("[data-purge]"), function (b) {
        b.addEventListener("click", function () {
          if (!window.confirm("Удалить все пакеты шейдеров игры " + b.dataset.purge + "? Игроки начнут собирать их заново.")) return;
          var p = b.dataset.purge.split("/");
          send("DELETE", "/v1/admin/shaders/" + encodeURIComponent(p[0]) + "/" + encodeURIComponent(p[1])).then(function () { say("shaderStatus", true, "Удалено"); loadShaders(); })
            .catch(function (e) { say("shaderStatus", false, "Не вышло: " + e.message); });
        });
      });
    }).catch(function (e) { $("shaderList").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }

  var VERDICT_NAMES = { works: "Работает", wontRun: "Не запустится" };
  function loadVerdicts() {
    api("/v1/verdicts").then(function (r) {
      table($("verdictList"), [["Игра"], ["Статус"], ["Номер в Steam"], ["Изменён"], [""]],
        (r.verdicts || []).map(function (v) {
          return '<tr><td class="title">' + gameName("", v.store, v.id) + '</td><td><span class="pill ' + (v.verdict === "works" ? "good" : "bad") + '">' + esc(VERDICT_NAMES[v.verdict] || v.verdict) +
            "</span></td><td>" + esc(v.steamAppID || "—") + "</td><td>" + when(v.updated ? new Date(v.updated).toISOString() : null) +
            '</td><td><button type="button" class="btn quiet" data-unverdict="' + esc(v.store + "/" + v.id) + '">Убрать</button></td></tr>';
        }));
      Array.prototype.forEach.call(document.querySelectorAll("[data-unverdict]"), function (b) {
        b.addEventListener("click", function () {
          if (!window.confirm("Убрать ваш статус у " + b.dataset.unverdict + "? Останутся голоса игроков.")) return;
          var p = b.dataset.unverdict.split("/");
          send("DELETE", "/v1/verdicts/" + encodeURIComponent(p[0]) + "/" + encodeURIComponent(p.slice(1).join("/"))).then(function () { say("vStatus", true, "Убрано"); loadVerdicts(); })
            .catch(function (e) { say("vStatus", false, "Не вышло: " + e.message); });
        });
      });
    }).catch(function (e) { $("verdictList").innerHTML = '<p class="note">Не удалось загрузить: ' + esc(e.message) + "</p>"; });
  }
  $("verdictForm").addEventListener("submit", function (e) {
    e.preventDefault();
    var store = $("vStore").value, id = $("vId").value.trim(), body = { verdict: $("vVerdict").value };
    if (store !== "steam" && $("vSteam").value.trim()) body.steamAppID = $("vSteam").value.trim();
    if (!window.confirm("Поставить «" + VERDICT_NAMES[body.verdict] + "» игре " + store + "/" + id + "? Игроки увидят этот статус.")) return;
    send("PUT", "/v1/verdicts/" + encodeURIComponent(store) + "/" + encodeURIComponent(id), body).then(function () { say("vStatus", true, "Сохранено"); $("verdictForm").reset(); loadVerdicts(); })
      .catch(function (e) { say("vStatus", false, "Не вышло: " + e.message); });
  });

  $("forgetForm").addEventListener("submit", function (e) {
    e.preventDefault();
    var client = $("fClient").value.trim().toLowerCase();
    if (!window.confirm("Удалить всё, что отправлено с установки " + client + "? Это нельзя отменить.")) return;
    send("POST", "/v1/forget", { client: client }).then(function (r) {
      say("fStatus", true, "Удалено: отчётов " + n(r.deleted.reports) + ", сбоев " + n(r.deleted.failures)); $("forgetForm").reset();
    }).catch(function (e) { say("fStatus", false, "Не вышло: " + (e.message === "client" ? "это не похоже на номер установки" : e.message)); });
  });

  load();
})();
</script>
</body>
</html>
`;
