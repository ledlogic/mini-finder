// mf-catalog.js
// Catalog row interactions: xref, sibling copy, cover, quickpick, species rules

// ── Copy sibling fields ──────────────────────────────────────────────────────
async function copySibling(imageId) {
  const btn = document.querySelector(`[data-id="${imageId}"].btn-copy-sibling`);
  const orig = btn.textContent;
  btn.textContent = '…';
  btn.disabled = true;

  let siblings;
  try {
    const res = await fetch(`/images/${imageId}/siblings`);
    if (!res.ok) { btn.textContent = '✕ no name set'; setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2000); return; }
    siblings = await res.json();
  } catch(e) {
    btn.textContent = '✕ error'; setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2000); return;
  }

  btn.textContent = orig;
  btn.disabled = false;

  if (!siblings.length) {
    btn.textContent = '✕ no siblings';
    setTimeout(() => { btn.textContent = orig; }, 2000);
    return;
  }

  // Filter to siblings that have useful data
  const populated = siblings.filter(s => s.species || s.gender || s.stance || s.weapons);
  const source = populated.length === 1 ? populated[0]
    : populated.length > 1  ? await pickSibling(populated)
    : siblings.length === 1 ? siblings[0]
    : await pickSibling(siblings);

  if (!source) return;

  fillFromSibling(imageId, source);
}

function fillFromSibling(imageId, source) {
  const row = document.getElementById(`row-${imageId}`);
  if (!row) return;

  const set = (name, val) => {
    const el = row.querySelector(`[name="${name}"]`);
    if (!el || !val) return;
    el.value = val;
    el.classList.add('cell-copied');
    setTimeout(() => el.classList.remove('cell-copied'), 2000);
  };

  set('species',   source.species);
  set('gender',    source.gender);
  set('stance',    source.stance);
  set('weapons',   source.weapons);
  set('mini_size', source.mini_size);

  // Flash the save button to remind user to save
  const saveBtn = row.querySelector('.btn-save');
  if (saveBtn) {
    saveBtn.style.background = 'var(--warn, #f59e0b)';
    setTimeout(() => saveBtn.style.background = '', 3000);
  }
}

function pickSibling(siblings) {
  return new Promise(resolve => {
    // Build a small inline picker
    const existing = document.getElementById('sibling-picker');
    if (existing) existing.remove();

    const picker = document.createElement('div');
    picker.id = 'sibling-picker';
    picker.className = 'sibling-picker';
    picker.innerHTML = `
      <div class="sibling-picker-inner">
        <div class="sibling-picker-title">Pick sibling to copy from:</div>
        ${siblings.map(s => `
          <button class="sibling-picker-btn" data-id="${s.id}">
            <strong>${s.mini_name}</strong>
            ${[s.stance, s.weapons, s.species, s.gender].filter(Boolean).map(v => `<span>${v}</span>`).join('')}
          </button>`).join('')}
        <button class="sibling-picker-cancel">Cancel</button>
      </div>`;

    picker.querySelectorAll('.sibling-picker-btn').forEach(b => {
      b.addEventListener('click', () => {
        picker.remove();
        resolve(siblings.find(s => s.id == b.dataset.id));
      });
    });
    picker.querySelector('.sibling-picker-cancel').addEventListener('click', () => { picker.remove(); resolve(null); });
    picker.addEventListener('click', e => { if (e.target === picker) { picker.remove(); resolve(null); } });

    document.body.appendChild(picker);
  });
}

// ── Inline collection name edit ──────────────────────────────────────────────
(function() {
  const input  = document.getElementById('col-name-input');
  const save   = document.getElementById('col-name-save');
  if (!input || !save) return;
  const orig = input.value;
  input.addEventListener('input', () => {
    save.style.display = input.value !== orig ? '' : 'none';
  });
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); input.closest('form').submit(); }
    if (e.key === 'Escape') { input.value = orig; save.style.display = 'none'; input.blur(); }
  });
})();

// ── Toggle the cross-reference (secondary image) select ─────────────────────
function toggleXrefSelect(imageId, checked) {
  const select = document.getElementById(`xref-select-${imageId}`);
  if (!select) return;
  select.style.opacity = checked ? '1' : '0.35';
  if (!checked) select.value = '';

  // Live-toggle visibility of name/species/gender fields, printed/painted,
  // and the secondary-of indicator.
  const row = document.getElementById(`row-${imageId}`);
  if (!row) return;
  row.classList.toggle('row-is-secondary', checked);

  // Name/species/gender are now all in one .cell-name-td cell
  const nameCell = row.querySelector('.cell-name-td');
  if (nameCell) {
    nameCell.querySelectorAll('input, select, button:not(.btn-suggestion)').forEach(el => {
      el.style.display = checked ? 'none' : '';
    });
    const suggestion = nameCell.querySelector('.btn-suggestion');
    if (suggestion) suggestion.style.display = checked ? 'none' : '';
  }

  // secondary-of indicator is now in the folder/file cell
  const secondaryOf = row.querySelector('.secondary-of');
  if (secondaryOf) secondaryOf.style.display = checked ? '' : 'none';

  // xref-row border/wrapper
  const xrefRow = row.querySelector('.xref-row');
  if (xrefRow) xrefRow.style.display = checked ? '' : '';  // always visible

  const dash = row.querySelector('.secondary-name-hidden');
  if (dash) dash.style.display = checked ? '' : 'none';

  const printedRow = row.querySelector('select[name="printed"]')?.closest('.count-row');
  const paintedRow = row.querySelector('select[name="painted"]')?.closest('.count-row');
  [printedRow, paintedRow].forEach(r => {
    if (r) r.style.display = checked ? 'none' : '';
  });
}

// ── Species that imply NA gender ─────────────────────────────────────────────
var NA_GENDER_SPECIES = ['ROBOT', 'VEHICLE', 'DRONE', 'CONSTRUCT', 'BEAST'];

function applySpeciesRules(speciesValue, row) {
  if (!row) return;
  var species = (speciesValue || '').toUpperCase();
  var implied = NA_GENDER_SPECIES.some(function(s) { return species.includes(s); });
  if (implied) {
    var genderSelect = row.querySelector('select[name="gender"]');
    if (genderSelect && genderSelect.value !== 'NA') {
      genderSelect.value = 'NA';
      genderSelect.dispatchEvent(new Event('change'));
      // Flash to draw attention
      genderSelect.style.transition = 'background 0.3s';
      genderSelect.style.background = 'rgba(0,212,255,0.2)';
      setTimeout(function() { genderSelect.style.background = ''; }, 1200);
    }
  }
}

// ── Field quick-pick buttons (species, stance, etc.) ─────────────────────────
function setFieldQuickpick(btn) {
  var fieldName = btn.dataset.field;
  var value     = btn.dataset.value;
  var row       = btn.closest('tr');
  var input     = row ? row.querySelector('input[name="' + fieldName + '"]') : null;
  if (!input) return;
  input.value = value;
  // Use 'change' not 'input' to avoid triggering autocomplete dropdown
  input.dispatchEvent(new Event('change'));
  closeAllAutocompletes();
  btn.closest('.species-quickpick').querySelectorAll('.btn-quickpick').forEach(function(b) {
    b.classList.toggle('btn-quickpick-active', b === btn);
  });
  // Auto-set gender to NA for non-gendered species
  if (fieldName === 'species') {
    applySpeciesRules(value, row);
    refreshAdaptiveButtons(value, row);
  }
}

// ── Dynamically refresh stance/weapons buttons when species changes ───────────
function refreshAdaptiveButtons(species, row) {
  var sp = (species || '').toUpperCase();
  var weaponsData = (window.MF_WEAPONS_BY_SPECIES && window.MF_WEAPONS_BY_SPECIES[sp] && window.MF_WEAPONS_BY_SPECIES[sp].length)
    ? window.MF_WEAPONS_BY_SPECIES[sp]
    : (window.MF_TOP_WEAPONS || []);
  var stanceData = (window.MF_STANCE_BY_SPECIES && window.MF_STANCE_BY_SPECIES[sp] && window.MF_STANCE_BY_SPECIES[sp].length)
    ? window.MF_STANCE_BY_SPECIES[sp]
    : (window.MF_TOP_STANCE || []);
  rebuildQuickpickGroup(row, 'weapons', weaponsData, sp ? sp + ' weapons:' : null);
  rebuildQuickpickGroup(row, 'stance',  stanceData,  sp ? sp + ' stances:' : null);
}

function rebuildQuickpickGroup(row, fieldName, values, labelText) {
  var input = row.querySelector('input[name="' + fieldName + '"]');
  if (!input || !values || !values.length) return;

  // Find a quickpick that belongs to this field — must be the immediate next sibling
  // (not searching further, to avoid stealing another field's quickpick)
  var container = null;
  var next = input.nextElementSibling;
  if (next && next.classList.contains('species-quickpick')) {
    container = next;
  }

  if (!container) {
    // Always insert directly after this input
    container = document.createElement('div');
    container.className = 'species-quickpick';
    input.insertAdjacentElement('afterend', container);
  }

  container.innerHTML = '';
  if (labelText) {
    var lbl = document.createElement('span');
    lbl.className = 'quickpick-label';
    lbl.textContent = labelText;
    container.appendChild(lbl);
  }
  var currentVal = input.value.trim().toUpperCase();
  values.forEach(function(val) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn-quickpick' + (currentVal === val ? ' btn-quickpick-active' : '');
    b.dataset.field = fieldName;
    b.dataset.value = val;
    b.textContent   = val;
    b.onclick = function() { setFieldQuickpick(b); };
    container.appendChild(b);
  });
}

// ── Edit page quick-pick buttons ──────────────────────────────────────────────
function editQuickpick(btn) {
  var targetId = btn.dataset.target;
  var value    = btn.dataset.value;
  var input    = document.getElementById(targetId);
  if (!input) return;
  input.value = value;
  input.dispatchEvent(new Event('change'));
  closeAllAutocompletes();
  btn.closest('.species-quickpick').querySelectorAll('.btn-quickpick').forEach(function(b) {
    b.classList.remove('btn-quickpick-active');
  });
  btn.classList.add('btn-quickpick-active');
  // Auto-set gender to NA for non-gendered species on edit page
  if (targetId === 'edit-species') {
    var genderSelect = document.querySelector('select[name="gender"]');
    var implied = NA_GENDER_SPECIES.some(function(s) { return value.toUpperCase().includes(s); });
    if (implied && genderSelect && genderSelect.value !== 'NA') {
      genderSelect.value = 'NA';
      genderSelect.style.transition = 'background 0.3s';
      genderSelect.style.background = 'rgba(0,212,255,0.2)';
      setTimeout(function() { genderSelect.style.background = ''; }, 1200);
    }
  }
}
// ── Search page quick-pick buttons ───────────────────────────────────────────
function searchQuickpick(btn) {
  var targetId = btn.dataset.target;
  var value    = btn.dataset.value;
  var input    = document.getElementById(targetId);
  if (!input) return;

  // Toggle: clicking active button clears it
  if (input.value.toUpperCase() === value.toUpperCase()) {
    input.value = '';
  } else {
    input.value = value;
  }

  // Update active state
  btn.closest('.species-quickpick').querySelectorAll('.btn-quickpick').forEach(function(b) {
    b.classList.toggle('btn-quickpick-active', b.dataset.value === input.value.toUpperCase());
  });

  // Auto-submit the search form
  var form = input.closest('form');
  if (form) form.submit();
}

// ── Check if a saved row no longer passes the active URL filters ──────────────
function rowFailsFilters(row) {
  var params = new URLSearchParams(window.location.search);

  function fieldVal(name) {
    var el = row.querySelector('[name="' + name + '"]');
    return el ? el.value.trim().toUpperCase() : '';
  }

  // f_no_weapons: row fails if weapons is now set
  if (params.get('f_no_weapons') === '1' && fieldVal('weapons') !== '') return true;

  // f_no_stance: row fails if stance is now set
  if (params.get('f_no_stance') === '1' && fieldVal('stance') !== '') return true;

  // f_no_species: row fails if species is now set
  if (params.get('f_no_species') === '1' && fieldVal('species') !== '') return true;

  // f_no_vehicles: row fails if species contains VEHICLE
  if (params.get('f_no_vehicles') === '1' && fieldVal('species').includes('VEHICLE')) return true;

  // f_no_robots: row fails if species contains ROBOT
  if (params.get('f_no_robots') === '1' && fieldVal('species').includes('ROBOT')) return true;

  // f_no_bundles: row fails if mini_count >= 4
  if (params.get('f_no_bundles') === '1') {
    var mc = row.querySelector('[name="mini_count"]');
    if (mc && (mc.value === '4+' || parseInt(mc.value) >= 4)) return true;
  }

  return false;
}
