/*
 * Dev harness for progress_window.html — NOT bundled into the app.
 *
 * Open the HTML straight from the repo with ?demo to replay a scripted
 * This-Week run against real Tidal cover URLs, without launching the app
 * (which would start a real scrape) or touching Spotify:
 *
 *   progress_window.html?demo         happy path — scrape → match → results
 *   progress_window.html?demo=fail    export fails after matching
 *   progress_window.html?demo=empty   scrape finds zero new tracks
 *
 * It stands in for the app's KeyboardMaestro shim: the page polls
 * GetVariable('NMRProgress') and this file feeds it a timeline of the same
 * JSON frames km_progress.py writes. window.__demoPush(patch) merges a patch
 * into the live state for ad-hoc testing from the console.
 */
(function(){
  'use strict';

  var variant = (location.search.match(/[?&]demo=([a-z]+)/) || [])[1] || 'ok';

  // Real covers scraped from Adrian's Tidal playlists (2026-07-18).
  var IMG = 'https://resources.tidal.com/images/';
  var T = [
    ['Picture Me Giving Af Who Don\'t Like Me.', 'Kai Ca$h', 'fd4e7bbd/156c/4b04/bab7/6f96c8d60e96'],
    ['Gold Chains', 'La Reezy', '7ca20472/bcbd/403a/9ce1/0cababd0474f'],
    ['Whole House', 'PFG, J. Cole', '551a5163/d0e3/4bd0/bc78/84c635000da7'],
    ['Forgive Never Forget', 'Luhh Dyl', 'db7d9374/cd79/466e/bfee/77478764693f'],
    ['Soul Ties', 'VonOff1700, Dreezy', '3aeae1b0/36a5/4a32/ae82/eb5f1c560208'],
    ['Big Dipper', 'Lelo', '2a101829/c80d/4e64/9572/df3c4f42c57c'],
    ['Nobody (feat. Monaleo) [Remix]', 'Trim, Monaleo', 'c054bd7f/89b7/48ba/ab52/3d58551fbc8e'],
    ['SATELLITE HIGH', 'MCVERTT, Kyle Richh, TaTa', 'bb92fc9b/4006/4dbb/a5cc/b061146ca158'],
    ['Westside', 'Kocky Ka', 'fa160153/b6e5/4b70/81a7/9a2929a93b11'],
    ['2 EASY', 'StressGods', '1f0c2e6d/8c38/4b77/bd26/360f1b6a0319'],
    ['Slippin Out Reality', 'Mai Mai', 'febef26c/7352/4509/968f/12b662721342'],
    ['maurice white (feat. BREY10)', 'DDK, BREY10', '98c49d5a/ccf5/4bb0/83d2/15dda0fb735c'],
    ['Not Average (feat. BunnaB)', 'HeadHuncho Amir, BunnaB', 'ff0b6054/e82b/4e72/980a/8e9b2abc73eb'],
    ['BabyDaddy', 'Poizonnn', 'd6ff3c6b/f560/4361/9114/76a25337c089'],
    ['like no other', 'Yoko', '71d60d2a/9a77/48e5/8367/0028a4cbd786'],
    ['What I Thought', 'GmoneyDt', '56007a91/cbea/49e8/b9ca/f23f453ec95c'],
    ['Drought', 'Baby Mel', '581f3e6e/b70b/4c59/bae5/d659c6f4d5b1'],
    ['Out Of Time', 'Yatta Bandz', '3f0950bb/22a8/415e/89a3/082f63289612'],
    ['Played First', 'Real Boston Richey', '89eee497/b0d2/42d9/a6f0/7f71bc59724e'],
    ['PIPEDOWN', 'ItGirl', '151d6dd4/376f/424e/95fb/533cf93c0a1b'],
    ['Family Bizzy', 'La Reezy', '80151d8f/70f7/49ca/a2bf/fc56acbd27ca'],
    ['YEAH!', 'Miles Minnick, DJ Mal-Ski', 'a684dca8/0762/4238/92be/8740fb9f3e19'],
    ['Parental Advisory (Remix)', 'NoLimit TC, Hotboii', '70207dc9/69ed/4d8b/8cb4/89f1291e2c27'],
    ['Money Calling', 'Luh Tyler', '767935f6/3971/4fdb/8ebe/9add9de7fd85'],
    ["WHAT'S YOUR INFO", 'Kalan.Frfr, Wallie the Sensei', '5aeed407/685f/476e/a4a2/b828a201ce30'],
    ['WTW THO?', 'Riotusa', 'e26a42f4/60d1/4813/be62/981f6a873360'],
    ['cHoPpEd ChEeSe!', 'Neemz', '333e4533/8a8c/4a5c/93bd/d40753d2bdd2'],
    ['7AM IN NY', 'Surf7', 'ea021099/1e60/4438/92a6/b15fe5a49af9'],
    ['Vending Machine Charcuterie Board With An Impossibly Long Title That Keeps On Going', 'Michael Christmas, Chris Crack, Girl Talk', '62a6b364/090d/418d/985a/b934ed5829c7'],
    ['ION GAFFF', 'Bani', '64b9883f/e619/4cf0/b0d6/76427ac057ff']
  ];
  var SOURCES = ['Rap Bars & Melodies', 'Hip-Hop: RISING', 'Viral Hype', 'New East Coast'];
  var tracks = T.map(function(t, i){
    return {
      title: t[0], artist: t[1],
      art: IMG + t[2] + '/320x320.jpg',
      video: '',
      source: SOURCES[i % SOURCES.length]
    };
  });
  // Deliberate edge cases:
  tracks[5].art = IMG + '00000000/dead/beef/0000/000000000000/320x320.jpg'; // 404s → tile hides / placeholder
  tracks[9].art = '';                                                       // no art at all → placeholder
  tracks[2].video = 'https://resources.tidal.com/videos/no/such/video/640x640.mp4'; // dead mp4 → image fallback

  var missed = tracks.slice(26);   // last 4 → "no Spotify match"
  var scraped = tracks.slice(0, 26);

  // ── the state object mirrors km_progress.py's _state shape ──
  var state = {
    mode: 'this-week', phase: 0, phaseTotal: 3, phaseLabel: 'INITIALIZING',
    overall: {current:0, total:0, label:'', pct:null},
    current: {name:'', detail:'', status:'idle', art:'', video:''},
    log: [], stats: {}, covers: [],
    tracks: {scraped:[], missed:[]},
    kmMacros: [], kmNote: '',
    done: false, ok: true, message: '', spotifyUri: '',
    busy: false, busyLabel: '', busyDetail: ''
  };
  var payload = '';
  function push(){ payload = JSON.stringify(state); }
  window.__demoPush = function(patch){
    Object.keys(patch || {}).forEach(function(k){ state[k] = patch[k]; });
    push();
  };

  window.KeyboardMaestro = {
    GetVariable: function(name){ return name === 'NMRProgress' ? payload : ''; },
    SetVariable: function(){}, ResizeWindow: function(){},
    Cancel: function(){}, Submit: function(){}
  };

  // ── timeline: [delayMs, mutator] pairs, run sequentially ──
  var steps = [];
  function at(delay, fn){ steps.push([delay, fn]); }

  at(200, function(){
    state.busy = true;
    state.busyLabel = 'CHECKING SPOTIFY';
    state.busyDetail = 'Looking for a This Week playlist created today…';
  });
  at(1400, function(){
    state.busy = false; state.busyLabel = ''; state.busyDetail = '';
    state.phase = 1; state.phaseLabel = 'SCRAPE TIDAL';
    state.overall = {current:0, total:SOURCES.length, label:'Scanning playlists', pct:null};
    state.log.push('Scraping tracks added in the last 7 days');
  });

  if (variant === 'empty') {
    SOURCES.forEach(function(name, i){
      at(700, function(){
        state.current = {name:name, detail:'scanned 214 · 0 recent', status:'scanning', art:'', video:''};
        state.overall.current = i + 1;
        state.log.push(name + ' — 0 matches out of 214 scanned');
      });
    });
    at(900, function(){
      state.done = true; state.ok = true;
      state.message = 'No new tracks found (added in the last 7 days)';
      state.kmNote = 'No Keyboard Maestro macros were fired — no playlist was created';
      state.current = {name:'', detail:'', status:'done', art:'', video:''};
    });
  } else {
    // Phase 1 — covers land one at a time while each playlist scans.
    var perList = Math.ceil(tracks.length / SOURCES.length);
    SOURCES.forEach(function(name, li){
      at(350, function(){
        state.current = {name:name, detail:'fetching…', status:'opening', art:'', video:''};
      });
      var mine = tracks.slice(li * perList, (li + 1) * perList);
      mine.forEach(function(t, ti){
        at(260, function(){
          if (t.art) state.covers.push({art:t.art, title:t.title, artist:t.artist, video:t.video});
          state.current = {name:name, detail:'scanned ' + ((ti+1)*23) + ' · ' + (ti+1) + ' recent',
                           status:'scanning', art:'', video:''};
        });
      });
      at(300, function(){
        state.overall.current = li + 1;
        state.log.push(name + ' — ' + mine.length + ' matches out of ' + (mine.length*23) + ' scanned');
      });
    });

    // Phase 2 — dedupe
    at(700, function(){
      state.phase = 2; state.phaseLabel = 'DEDUPE & SNAPSHOT';
      state.current = {name:'Dedupe', detail: tracks.length + ' recent matches found', status:'working', art:'', video:''};
    });
    at(800, function(){
      state.stats = {recent: tracks.length + 4, unique: tracks.length, duplicates: 4};
      state.log.push(tracks.length + ' unique tracks (4 duplicates removed)');
    });

    // Phase 3 — export
    at(700, function(){
      state.phase = 3; state.phaseLabel = 'EXPORT TO SPOTIFY';
      state.busy = true; state.busyLabel = 'EXPORTING TO SPOTIFY';
      state.busyDetail = 'Matching tracks on Spotify and building your playlist — this can take a moment…';
    });
    at(1600, function(){
      state.busy = false; state.busyLabel = ''; state.busyDetail = '';
      state.overall = {current:0, total:tracks.length, label:'MATCHING ON SPOTIFY', pct:0};
    });
    tracks.forEach(function(t, i){
      at(200, function(){
        var nMissed = Math.max(0, Math.min(i - 25, missed.length));
        state.current = {name: t.title + ' — ' + t.artist,
                         detail: Math.min(i, 26) + ' matched · ' + nMissed + ' missed',
                         status:'exporting', art:t.art, video:t.video};
        state.overall.current = i + 1;
        state.overall.pct = (i + 1) / tracks.length * 90;
      });
    });

    if (variant === 'fail') {
      at(900, function(){
        state.done = true; state.ok = false;
        state.message = 'Spotify export failed';
        state.kmNote = 'No Keyboard Maestro macros were fired — no playlist was created';
        state.current = {name:'', detail:'', status:'done', art:'', video:''};
      });
    } else {
      [['Creating playlist', '🪁 DX 07-18-26', 92],
       ['Adding tracks to playlist', '26 tracks', 95],
       ['Rendering cover artwork', 'HTML/CSS → Playwright → JPEG', 97],
       ['Uploading cover art', 'Sending artwork to Spotify', 99]].forEach(function(step){
        at(650, function(){
          state.current = {name: step[0], detail: step[1], status:'exporting', art:'', video:''};
          state.overall.pct = step[2];
        });
      });
      at(800, function(){
        state.tracks = {scraped: scraped, missed: missed};
        state.done = true; state.ok = true;
        state.message = 'Playlist created — opening in Spotify';
        state.spotifyUri = 'spotify:playlist:demo';
        state.current = {name:'', detail:'', status:'done', art:'', video:''};
      });
      at(600, function(){
        state.kmMacros.push({name: '▶ New Music Research (2) — Open Results',
                             uuid: '3A811FCB-BF75-4507-A09F-083C73B4B382'});
      });
    }
  }

  var i = 0;
  function next(){
    if (i >= steps.length) return;
    var step = steps[i++];
    setTimeout(function(){ step[1](); push(); next(); }, step[0]);
  }
  push();
  next();
})();
