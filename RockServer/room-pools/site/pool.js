(function () {
  'use strict';

  var WRITE_KEY_STORAGE = 'rock_pool_write_token';

  var consumerCard = document.getElementById('consumer-card');
  var poolHeading = document.getElementById('pool-heading');
  var poolBadge = document.getElementById('pool-badge');
  var poolMeta = document.getElementById('pool-meta');
  var poolOrigins = document.getElementById('pool-origins');
  var coordUrlDisplay = document.getElementById('coord-url-display');
  var manageLinkBox = document.getElementById('manage-link-box');
  var manageUrlDisplay = document.getElementById('manage-url-display');
  var claimRoomBtn = document.getElementById('claim-room-btn');
  var copyCoordBtn = document.getElementById('copy-coord-btn');
  var copyManageBtn = document.getElementById('copy-manage-btn');
  var claimedBox = document.getElementById('claimed-box');
  var claimedUrlEl = document.getElementById('claimed-url');
  var copyClaimedBtn = document.getElementById('copy-claimed-btn');
  var openClaimedLink = document.getElementById('open-claimed-link');
  var consumerStatus = document.getElementById('consumer-status');

  var manageHeading = document.getElementById('manage-heading');
  var managePill = document.getElementById('manage-pill');
  var writeTokenInput = document.getElementById('write-token-input');
  var newPoolIdInput = document.getElementById('new-pool-id');
  var newPoolLabelInput = document.getElementById('new-pool-label');
  var createPoolBtn = document.getElementById('create-pool-btn');
  var manageLinksSection = document.getElementById('manage-links-section');
  var bulkLinksInput = document.getElementById('bulk-links-input');
  var addLinksBtn = document.getElementById('add-links-btn');
  var loadLinksBtn = document.getElementById('load-links-btn');
  var clearLinksBtn = document.getElementById('clear-links-btn');
  var queuedLinksWrap = document.getElementById('queued-links-wrap');
  var queuedLinksSummary = document.getElementById('queued-links-summary');
  var queuedLinksList = document.getElementById('queued-links-list');
  var manageStatus = document.getElementById('manage-status');

  var state = {
    poolId: null,
    auth: null,
    writeToken: null,
    lastClaimedUrl: null
  };
  var preferGetRpc = false;

  function parseParams(raw) {
    var result = {};
    if (!raw) return result;
    var clean = raw.replace(/^[?#&]+/, '');
    clean.split('&').forEach(function (pair) {
      if (!pair) return;
      var eq = pair.indexOf('=');
      if (eq < 0) return;
      var k = decodeURIComponent(pair.slice(0, eq));
      var v = decodeURIComponent(pair.slice(eq + 1));
      result[k] = v;
    });
    return result;
  }

  function parseCurrentLocation() {
    var path = window.location.pathname || '';
    var match = path.match(/^\/pools\/([^/?#]+)$/);
    var poolId = null;
    var pathParams = {};
    if (match) {
      var seg = match[1];
      var amp = seg.indexOf('&');
      if (amp >= 0) {
        poolId = decodeURIComponent(seg.slice(0, amp)).toLowerCase();
        pathParams = parseParams(seg.slice(amp + 1));
      } else {
        poolId = decodeURIComponent(seg).toLowerCase();
      }
    }
    var hashParams = parseParams(window.location.hash);
    var queryParams = parseParams(window.location.search);
    var auth = hashParams.auth || queryParams.auth || pathParams.auth || null;
    var write = hashParams.write || queryParams.write || pathParams.write || null;
    return {
      poolId: poolId,
      auth: auth,
      write: write,
      needsCanonicalUrl: Boolean(poolId && auth && (window.location.search || pathParams.auth || pathParams.write))
    };
  }

  function canonicalCoordUrl(poolId, auth) {
    return window.location.origin + '/pools/' + encodeURIComponent(poolId) + '#auth=' + encodeURIComponent(auth);
  }

  function canonicalManageUrl(poolId, auth, writeToken) {
    return canonicalCoordUrl(poolId, auth) + '&write=' + encodeURIComponent(writeToken);
  }

  function setStatus(el, msg, kind) {
    el.textContent = msg || '';
    el.className = 'status' + (kind ? ' ' + kind : '');
  }

  function makeUuid() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    return String(Date.now()) + '-' + Math.random().toString(16).slice(2);
  }

  function getWriteToken() {
    return (writeTokenInput.value || '').trim();
  }

  function getPoolWriteToken() {
    return getWriteToken() || state.writeToken || '';
  }

  function persistWriteToken() {
    var tok = getWriteToken();
    try {
      if (tok) window.sessionStorage.setItem(WRITE_KEY_STORAGE, tok);
      else window.sessionStorage.removeItem(WRITE_KEY_STORAGE);
    } catch (_) {}
  }

  function restoreWriteToken() {
    try {
      var saved = window.sessionStorage.getItem(WRITE_KEY_STORAGE);
      if (saved) writeTokenInput.value = saved;
    } catch (_) {}
  }

  function encodeBase64Url(obj) {
    var bytes = new TextEncoder().encode(JSON.stringify(obj || {}));
    var bin = '';
    for (var i = 0; i < bytes.length; i++) {
      bin += String.fromCharCode(bytes[i]);
    }
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  }

  function actionForPostPath(path) {
    if (path === '/api/pools') return 'create';
    if (path.slice(-6) === '/claim') return 'claim';
    if (path.slice(-6) === '/links') return 'add_links';
    if (path.slice(-13) === '/links/remove') return 'remove_links';
    return null;
  }

  function sendGetAction(path, action, opts) {
    var headers = { Accept: 'application/json', 'X-Pool-Action': action };
    if (opts.auth) headers.Authorization = 'Bearer ' + opts.auth;
    if (opts.writeToken) headers['X-Pool-Write-Token'] = opts.writeToken;
    if (opts.body !== undefined) headers['X-Pool-Payload'] = encodeBase64Url(opts.body);
    var sep = path.indexOf('?') >= 0 ? '&' : '?';
    var url = path + sep + 'rid=' + encodeURIComponent(makeUuid());
    return fetch(url, { method: 'GET', headers: headers, cache: 'no-store' });
  }

  function apiRequest(path, options) {
    var opts = options || {};
    var method = opts.method || 'GET';
    var action = method === 'POST' ? actionForPostPath(path) : null;

    var sendPromise;
    if (method === 'POST' && action && preferGetRpc) {
      sendPromise = sendGetAction(path, action, opts);
    } else {
      var headers = { Accept: 'application/json' };
      if (opts.auth) headers.Authorization = 'Bearer ' + opts.auth;
      if (opts.writeToken) headers['X-Pool-Write-Token'] = opts.writeToken;
      var fetchOpts = { method: method, headers: headers, cache: 'no-store' };
      if (opts.body !== undefined) {
        headers['Content-Type'] = 'application/json';
        fetchOpts.body = JSON.stringify(opts.body);
      }
      sendPromise = fetch(path, fetchOpts).then(function (resp) {
        if (resp.status === 405 && method === 'POST' && action) {
          preferGetRpc = true;
          return sendGetAction(path, action, opts);
        }
        return resp;
      });
    }

    return sendPromise.then(function (resp) {
      return resp.json().catch(function () { return {}; }).then(function (data) {
        if (!resp.ok) {
          var err = new Error(data.message || ('HTTP ' + resp.status));
          err.status = resp.status;
          err.code = data.error;
          throw err;
        }
        return data;
      });
    });
  }

  function extractCandidateLinks(rawText) {
    var matches = rawText.match(/https:\/\/[^\s<>"'`]+/gi) || [];
    var seen = {};
    var out = [];
    matches.forEach(function (item) {
      var cleaned = item.replace(/[.,;!?)\]>'"]+$/g, '');
      if (cleaned && !seen[cleaned]) {
        seen[cleaned] = true;
        out.push(cleaned);
      }
    });
    return out;
  }

  function renderPoolStatus(status) {
    consumerCard.hidden = false;
    manageLinksSection.hidden = false;
    manageHeading.textContent = 'MANAGE POOL · ' + status.poolId;
    poolHeading.textContent = status.label ? ('POOL · ' + status.poolId + ' · ' + status.label) : ('POOL · ' + status.poolId);
    poolBadge.textContent = status.availableCount + ' available';
    poolMeta.textContent = status.availableCount + ' unused · ' + status.usedCount + ' already used';
    coordUrlDisplay.textContent = canonicalCoordUrl(state.poolId, state.auth);
    if (state.writeToken) {
      manageLinkBox.hidden = false;
      copyManageBtn.hidden = false;
      manageUrlDisplay.textContent = canonicalManageUrl(state.poolId, state.auth, state.writeToken);
      managePill.textContent = 'Admin link active';
    } else {
      manageLinkBox.hidden = true;
      copyManageBtn.hidden = true;
      manageUrlDisplay.textContent = '';
      managePill.textContent = 'Write password required';
    }
    claimRoomBtn.disabled = status.availableCount <= 0;

    poolOrigins.innerHTML = '';
    var originKeys = Object.keys(status.origins || {});
    originKeys.sort().forEach(function (origin) {
      var chip = document.createElement('span');
      chip.className = 'origin-chip';
      chip.textContent = origin.replace(/^https:\/\//, '') + ' · ' + status.origins[origin];
      poolOrigins.appendChild(chip);
    });
  }

  function refreshStatus() {
    if (!state.poolId || !state.auth) return Promise.resolve();
    return apiRequest('/api/pools/' + encodeURIComponent(state.poolId), { auth: state.auth })
      .then(function (status) {
        renderPoolStatus(status);
      })
      .catch(function (err) {
        consumerCard.hidden = false;
        setStatus(consumerStatus, err.message, 'error');
      });
  }

  function renderQueuedLinks(data) {
    queuedLinksWrap.hidden = false;
    queuedLinksSummary.textContent = data.availableCount + ' unused link(s) currently queued in pool ' + data.poolId + ':';
    queuedLinksList.innerHTML = '';
    (data.links || []).forEach(function (entry) {
      var li = document.createElement('li');
      li.className = 'queued-item';
      var code = document.createElement('code');
      code.textContent = entry.url;
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'queued-remove';
      btn.textContent = 'Remove';
      btn.addEventListener('click', function () {
        removeByIds([entry.id]);
      });
      li.appendChild(code);
      li.appendChild(btn);
      queuedLinksList.appendChild(li);
    });
  }

  function loadQueuedLinks() {
    var writeToken = getPoolWriteToken();
    if (!writeToken) {
      setStatus(manageStatus, 'Enter the write password or open the manage link first.', 'error');
      return;
    }
    if (getWriteToken()) persistWriteToken();
    setStatus(manageStatus, 'Loading queued links…', '');
    apiRequest('/api/pools/' + encodeURIComponent(state.poolId) + '/links', {
      auth: state.auth,
      writeToken: writeToken
    }).then(function (data) {
      renderQueuedLinks(data);
      setStatus(manageStatus, 'Loaded ' + data.links.length + ' unused link(s).', 'ok');
    }).catch(function (err) {
      setStatus(manageStatus, err.message, 'error');
    });
  }

  function removeByIds(ids) {
    var writeToken = getPoolWriteToken();
    if (!writeToken) {
      setStatus(manageStatus, 'Enter the write password or open the manage link first.', 'error');
      return;
    }
    if (getWriteToken()) persistWriteToken();
    apiRequest('/api/pools/' + encodeURIComponent(state.poolId) + '/links/remove', {
      method: 'POST',
      auth: state.auth,
      writeToken: writeToken,
      body: { ids: ids }
    }).then(function (res) {
      setStatus(manageStatus, 'Removed ' + res.removed + ' link(s). ' + res.availableCount + ' available.', 'ok');
      refreshStatus();
      loadQueuedLinks();
    }).catch(function (err) {
      setStatus(manageStatus, err.message, 'error');
    });
  }

  function copyText(text, statusEl, message) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      setStatus(statusEl, 'Copy manually from the box above.', '');
      return;
    }
    navigator.clipboard.writeText(text).then(function () {
      setStatus(statusEl, message, 'ok');
    }).catch(function () {
      setStatus(statusEl, 'Copy manually from the box above.', '');
    });
  }

  claimRoomBtn.addEventListener('click', function () {
    setStatus(consumerStatus, 'Claiming an unused room…', '');
    apiRequest('/api/pools/' + encodeURIComponent(state.poolId) + '/claim', {
      method: 'POST',
      auth: state.auth,
      body: { requestId: makeUuid() }
    }).then(function (res) {
      state.lastClaimedUrl = res.roomUrl;
      claimedBox.hidden = false;
      claimedUrlEl.textContent = res.roomUrl;
      openClaimedLink.href = res.roomUrl;
      copyText(res.roomUrl, consumerStatus, 'Claimed room link copied (' + res.remainingCount + ' left).');
      refreshStatus();
    }).catch(function (err) {
      setStatus(consumerStatus, err.message, 'error');
      refreshStatus();
    });
  });

  copyCoordBtn.addEventListener('click', function () {
    if (!state.poolId || !state.auth) return;
    copyText(canonicalCoordUrl(state.poolId, state.auth), consumerStatus, 'Coordination link copied.');
  });

  copyManageBtn.addEventListener('click', function () {
    if (!state.poolId || !state.auth || !state.writeToken) return;
    copyText(canonicalManageUrl(state.poolId, state.auth, state.writeToken), consumerStatus, 'Manage link copied.');
  });

  copyClaimedBtn.addEventListener('click', function () {
    if (!state.lastClaimedUrl) return;
    copyText(state.lastClaimedUrl, consumerStatus, 'Claimed room link copied.');
  });

  createPoolBtn.addEventListener('click', function () {
    var writeToken = getWriteToken();
    if (!writeToken) {
      setStatus(manageStatus, 'Enter the write password first.', 'error');
      return;
    }
    persistWriteToken();
    var body = {};
    var pid = newPoolIdInput.value.trim();
    var lbl = newPoolLabelInput.value.trim();
    if (pid) body.poolId = pid;
    if (lbl) body.label = lbl;

    setStatus(manageStatus, 'Creating pool…', '');
    apiRequest('/api/pools', {
      method: 'POST',
      writeToken: writeToken,
      body: body
    }).then(function (res) {
      state.poolId = res.poolId;
      state.auth = res.auth;
      state.writeToken = res.writeToken || null;
      var targetUrl = res.writeToken
        ? canonicalManageUrl(res.poolId, res.auth, res.writeToken)
        : canonicalCoordUrl(res.poolId, res.auth);
      var relUrl = '/pools/' + encodeURIComponent(res.poolId) + '#auth=' + encodeURIComponent(res.auth)
        + (res.writeToken ? '&write=' + encodeURIComponent(res.writeToken) : '');
      window.history.replaceState(null, '', relUrl);
      setStatus(manageStatus, 'Created pool ' + res.poolId + '.', 'ok');
      copyText(canonicalCoordUrl(res.poolId, res.auth), consumerStatus, 'New coordination link copied (use Manage link above to edit links).');
      refreshStatus();
    }).catch(function (err) {
      setStatus(manageStatus, err.message, 'error');
    });
  });

  addLinksBtn.addEventListener('click', function () {
    var writeToken = getPoolWriteToken();
    if (!writeToken) {
      setStatus(manageStatus, 'Enter the write password or open the manage link first.', 'error');
      return;
    }
    if (getWriteToken()) persistWriteToken();
    var links = extractCandidateLinks(bulkLinksInput.value || '');
    if (!links.length) {
      setStatus(manageStatus, 'Paste at least one https:// meeting link first.', 'error');
      return;
    }
    setStatus(manageStatus, 'Uploading ' + links.length + ' link(s)…', '');
    var chunks = [];
    for (var i = 0; i < links.length; i += 20) {
      chunks.push(links.slice(i, i + 20));
    }
    var totals = { added: 0, skippedDuplicates: 0, invalid: 0, availableCount: 0 };
    var chain = Promise.resolve();
    chunks.forEach(function (batch) {
      chain = chain.then(function () {
        return apiRequest('/api/pools/' + encodeURIComponent(state.poolId) + '/links', {
          method: 'POST',
          auth: state.auth,
          writeToken: writeToken,
          body: { links: batch }
        }).then(function (res) {
          totals.added += res.added || 0;
          totals.skippedDuplicates += res.skippedDuplicates || 0;
          totals.invalid += res.invalid || 0;
          totals.availableCount = res.availableCount;
        });
      });
    });
    chain.then(function () {
      bulkLinksInput.value = '';
      setStatus(
        manageStatus,
        'Added ' + totals.added + ', skipped ' + totals.skippedDuplicates + ' duplicate(s), ' + totals.invalid + ' invalid. ' + totals.availableCount + ' available.',
        'ok'
      );
      refreshStatus();
      if (!queuedLinksWrap.hidden) loadQueuedLinks();
    }).catch(function (err) {
      setStatus(manageStatus, err.message, 'error');
    });
  });

  loadLinksBtn.addEventListener('click', loadQueuedLinks);

  clearLinksBtn.addEventListener('click', function () {
    var writeToken = getPoolWriteToken();
    if (!writeToken) {
      setStatus(manageStatus, 'Enter the write password or open the manage link first.', 'error');
      return;
    }
    if (getWriteToken()) persistWriteToken();
    apiRequest('/api/pools/' + encodeURIComponent(state.poolId) + '/links/remove', {
      method: 'POST',
      auth: state.auth,
      writeToken: writeToken,
      body: { clearAvailable: true }
    }).then(function (res) {
      setStatus(manageStatus, 'Cleared ' + res.removed + ' unused link(s).', 'ok');
      refreshStatus();
      if (!queuedLinksWrap.hidden) loadQueuedLinks();
    }).catch(function (err) {
      setStatus(manageStatus, err.message, 'error');
    });
  });

  restoreWriteToken();
  var parsed = parseCurrentLocation();
  if (parsed.poolId && parsed.auth) {
    state.poolId = parsed.poolId;
    state.auth = parsed.auth;
    state.writeToken = parsed.write || null;
    if (parsed.needsCanonicalUrl) {
      var canonicalRel = '/pools/' + encodeURIComponent(parsed.poolId) + '#auth=' + encodeURIComponent(parsed.auth)
        + (parsed.write ? '&write=' + encodeURIComponent(parsed.write) : '');
      window.history.replaceState(null, '', canonicalRel);
    }
    refreshStatus().then(function () {
      if (state.writeToken) {
        loadQueuedLinks();
      }
    });
  }
})();
