import Foundation

enum ReportInteraction {
    static let script = #"""
    (() => {
      'use strict';
      const rank = level => ({EMERGENCY:8,ALERT:7,CRITICAL:6,ERROR:5,WARNING:4,WARN:4,NOTICE:3,INFO:2,DEBUG:1}[level] || 0);
      const norm = value => String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLocaleLowerCase('fr');
      const finite = value => Number.isFinite(value) ? Math.max(0, value) : 0;
      const dayKey = value => {
        const match = String(value || '').match(/^\d{4}-\d{2}-\d{2}(?=$|T|\s)/);
        if (!match) return 'undated';
        const day = match[0], check = new Date(day + 'T00:00:00Z');
        return Number.isFinite(check.getTime()) && check.toISOString().slice(0,10) === day ? day : 'undated';
      };
      function selectLogs(logs, filters = {}) {
        const {drone='',family='',level='',query='',day=''} = filters;
        const search = norm(query.trim());
        const hasMessageFilter = Boolean(family || level || search);
        return logs.flatMap(log => {
          if (drone && log.droneID !== drone) return [];
          if (day && !dayKey(log.date).startsWith(day)) return [];
          const matchesLog = search && norm([log.droneName,log.sourceName,log.droneID,log.id,log.fileName,log.date].join(' ')).includes(search);
          const messages = log.messages.filter(message => {
            if (family && message.family !== family) return false;
            if (level === 'ALERTS' && !message.isAlert) return false;
            if (level === 'ERROR+' && rank(message.level) < 5) return false;
            if (level === 'WARNING+' && rank(message.level) < 4) return false;
            if (level && !['ALERTS','ERROR+','WARNING+'].includes(level) && message.level !== level) return false;
            return !search || matchesLog || norm([message.text,message.title,message.family].join(' ')).includes(search);
          });
          if (hasMessageFilter && !messages.length && !(matchesLog && !family && !level)) return [];
          return [{log,messages,includeFailsafe:!hasMessageFilter}];
        });
      }
      const withAlerts = item => item.log.status !== 'error' && (item.messages.some(m => m.isAlert) || (item.includeFailsafe && item.log.failsafeObserved));
      function statistics(selected) {
        const valid = selected.filter(item => item.log.status !== 'error');
        return {
          logCount:selected.length, droneCount:new Set(selected.map(item => item.log.droneID)).size,
          validLogCount:valid.length, durationSeconds:valid.reduce((sum,item) => sum + finite(item.log.durationSeconds),0),
          alertLogCount:selected.filter(withAlerts).length,
          messageCount:selected.reduce((sum,item) => sum + item.messages.length,0),
          alertMessageCount:valid.reduce((sum,item) => sum + item.messages.filter(m => m.isAlert).length,0),
          failedLogCount:selected.filter(item => item.log.status === 'error').length,
          partialLogCount:selected.filter(item => item.log.status === 'partial').length,
          failsafeLogCount:valid.filter(item => item.includeFailsafe && item.log.failsafeObserved).length
        };
      }
      function familyCounts(selected) {
        const families = new Map();
        for (const {log,messages} of selected) {
          if (log.status === 'error') continue;
          for (const name of new Set(messages.filter(m => m.isAlert).map(m => m.family))) {
            if (!families.has(name)) families.set(name,new Set());
            families.get(name).add(log.id);
          }
        }
        return [...families].map(([name,ids]) => ({name,count:ids.size})).sort((a,b) => a.name.localeCompare(b.name,'fr'));
      }
      function dailyCounts(selected) {
        const days = new Map();
        for (const item of selected) {
          const day = dayKey(item.log.date);
          if (!days.has(day)) days.set(day,{day,total:0,alerts:0});
          days.get(day).total++; if (withAlerts(item)) days.get(day).alerts++;
        }
        return [...days.values()].sort((a,b) => a.day.localeCompare(b.day));
      }
      if (typeof module !== 'undefined' && module.exports) module.exports = {selectLogs,statistics,familyCounts,dailyCounts,dayKey};
      if (typeof document === 'undefined') return;
      const $ = id => document.getElementById(id);
      const el = (tag, className, text) => {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };
      const svgEl = (tag, attrs = {}, text) => {
        const node = document.createElementNS('http://www.w3.org/2000/svg',tag);
        for (const [key,value] of Object.entries(attrs)) node.setAttribute(key,String(value));
        if (text !== undefined) node.textContent = text;
        return node;
      };
      const integer = new Intl.NumberFormat('fr-FR');
      const decimal = new Intl.NumberFormat('fr-FR',{maximumFractionDigits:1});
      const count = (n, noun) => integer.format(n) + ' ' + noun + (n > 1 ? 's' : '');
      const prettyDay = day => day === 'undated' ? 'Date inconnue' : day.length === 10 ? day.slice(8) + '/' + day.slice(5,7) + '/' + day.slice(0,4) : day.length === 7 ? day.slice(5) + '/' + day.slice(0,4) : day;
      function button(label, action, className) {
        const node = el('button',className,label); node.type = 'button'; node.addEventListener('click',action); return node;
      }
      try {
        const data = JSON.parse($('report-data').textContent);
        const filters = {drone:'',family:'',level:'',query:'',day:''};
        const cards = [...document.querySelectorAll('.log-card')];
        const groupCards = [...document.querySelectorAll('.alert-group')];
        let current = [], pendingSearch;
        const empty = (container,text) => container.replaceChildren(el('p','empty-state',text));
        function filterFamily(name) { filters.family = filters.family === name ? '' : name; $('family-filter').value = filters.family; render(); }
        function drawFamilies(selected,stats) {
          const values = familyCounts(selected), container = $('family-chart'), legend = $('family-legend');
          container.replaceChildren(); legend.replaceChildren();
          $('radar-scale').textContent = '0 — ' + count(stats.validLogCount,'log');
          if (!values.length) {
            empty(container,stats.failsafeLogCount ? 'Failsafe observé, sans famille d’alerte textuelle dans ce périmètre.' : 'Aucune alerte textuelle repérée dans ce périmètre.'); return;
          }
          const maximum = Math.max(1,stats.validLogCount);
          if (values.length >= 3 && values.length <= 8) {
            const svg = svgEl('svg',{viewBox:'0 0 440 320',class:'radar',role:'group','aria-label':'Profil des alertes, nombre de logs concernés par famille'});
            const point = (i,r) => { const a = -Math.PI/2 + i*2*Math.PI/values.length; return [220+Math.cos(a)*r,150+Math.sin(a)*r]; };
            for (let step=1; step<=4; step++) svg.append(svgEl('polygon',{points:values.map((_,i)=>point(i,100*step/4).join(',')).join(' '),class:'radar-grid'}));
            values.forEach((value,i) => { const [x,y] = point(i,100); svg.append(svgEl('line',{x1:220,y1:150,x2:x,y2:y,class:'radar-grid'})); });
            svg.append(svgEl('polygon',{points:values.map((value,i)=>point(i,100*value.count/maximum).join(',')).join(' '),class:'radar-shape'}));
            values.forEach((value,i) => {
              const [x,y] = point(i,100*value.count/maximum), [lx,ly] = point(i,124);
              const label = value.name.length > 17 ? value.name.slice(0,16)+'…' : value.name;
              svg.append(svgEl('text',{x:lx,y:ly,'text-anchor':lx<210?'end':lx>230?'start':'middle','dominant-baseline':'middle',class:'radar-label'},label));
              const dot = svgEl('circle',{cx:x,cy:y,r:5,class:'radar-dot',tabindex:0,role:'button','aria-label':value.name+' : '+count(value.count,'log')+'. Filtrer cette famille.'});
              dot.append(svgEl('title',{},value.name+' · '+count(value.count,'log')));
              dot.addEventListener('click',()=>filterFamily(value.name));
              dot.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();filterFamily(value.name);}});
              svg.append(dot);
            });
            container.append(svg);
            for (const value of values) {
              const control = button(value.name+' · '+value.count,()=>filterFamily(value.name));
              control.setAttribute('aria-pressed',String(filters.family===value.name)); legend.append(control);
            }
          } else {
            const bars = el('div','family-bars');
            for (const value of values) {
              const row = button('',()=>filterFamily(value.name),'family-row');
              row.setAttribute('aria-pressed',String(filters.family===value.name));
              const track = el('span','bar-track'), fill = el('span','bar-fill');
              fill.style.width = (100*value.count/maximum)+'%'; track.append(fill);
              row.append(el('span','',value.name),track,el('strong','',integer.format(value.count))); bars.append(row);
            }
            container.append(bars);
          }
        }
        function drawTimeline(selected) {
          const container = $('timeline-chart'), daily = dailyCounts(selected);
          container.replaceChildren();
          if (!daily.length) { empty(container,'Aucun enregistrement pour ces filtres.'); return; }
          const dated = daily.filter(item=>item.day!=='undated');
          let length = dated.length > 24 ? 7 : 10;
          if (new Set(dated.map(item=>item.day.slice(0,length))).size > 24) length = 4;
          const buckets = new Map();
          for (const value of daily) {
            const key = value.day === 'undated' ? value.day : value.day.slice(0,length);
            if (!buckets.has(key)) buckets.set(key,{day:key,total:0,alerts:0});
            const item = buckets.get(key); item.total += value.total; item.alerts += value.alerts;
          }
          $('timeline-caption').textContent = 'Fichiers par '+(length===10?'jour':length===7?'mois':'année')+' · cliquer pour filtrer la période.';
          const maximum = Math.max(...[...buckets.values()].map(item=>item.total),1);
          for (const item of buckets.values()) {
            const label = prettyDay(item.day), control = button('',()=>{filters.day = filters.day===item.day?'':item.day;render();},'timeline-column');
            control.setAttribute('aria-label',label+' : '+count(item.total,'fichier')+', '+count(item.alerts,'log')+' avec alertes. Filtrer cette période.');
            control.setAttribute('aria-pressed',String(filters.day===item.day));
            control.title = label+' · '+item.total+' fichiers · '+item.alerts+' avec alertes';
            const bars = el('span','timeline-bars'), total = el('span','timeline-total'), alert = el('span','timeline-alert');
            total.style.height = (100*item.total/maximum)+'%'; alert.style.height = (100*item.alerts/maximum)+'%';
            bars.append(total,alert);
            control.append(el('strong','timeline-value',String(item.total)),bars,el('span','timeline-label',label)); container.append(control);
          }
        }
        function render() {
          current = selectLogs(data.logs,filters);
          const stats = statistics(current), byLog = new Map(current.map(item=>[item.log.id,item])), groups = new Map();
          for (const item of current) for (const message of item.messages) {
            if (!groups.has(message.groupKey)) groups.set(message.groupKey,{messages:0,logs:new Set()});
            const group=groups.get(message.groupKey); group.messages++; group.logs.add(item.log.id);
          }
          $('stat-drones').textContent = integer.format(stats.droneCount);
          $('stat-logs').textContent = integer.format(stats.logCount);
          $('stat-quality').textContent = count(stats.validLogCount,'lisible')+' · '+stats.failedLogCount+' en erreur';
          $('stat-duration').replaceChildren(document.createTextNode(decimal.format(stats.durationSeconds/60)),el('em','',' min'));
          $('stat-alerts').replaceChildren(document.createTextNode(integer.format(stats.alertLogCount)),el('em','',' / '+stats.validLogCount));
          $('stat-alert-detail').textContent = count(stats.alertMessageCount,'message')+' d’alerte'+(stats.failsafeLogCount?' · '+count(stats.failsafeLogCount,'log')+' avec failsafe':'');
          const scope = [];
          if(filters.drone) scope.push($('drone-filter').selectedOptions[0].textContent);
          if(filters.family) scope.push(filters.family);
          if(filters.level) scope.push($('level-filter').selectedOptions[0].textContent);
          if(filters.query.trim()) scope.push('Recherche : '+filters.query.trim());
          if(filters.day) scope.push('Période : '+prettyDay(filters.day));
          $('filter-status').textContent = (scope.length?scope.join(' · '):'Toute la bibliothèque')+' — '+stats.logCount+' / '+data.logs.length+' fichiers · '+count(stats.messageCount,'message');
          $('reset-filters').disabled = !scope.length;
          $('group-summary').textContent = count(groups.size,'groupe')+' · '+count(stats.messageCount,'message');
          $('groups-empty').hidden = groups.size>0; $('logs-empty').hidden = current.length>0;
          for (const card of cards) {
            const item = byLog.get(card.dataset.log); card.hidden = !item;
            if (!item) continue;
            card.querySelector('.visible-message-count').textContent = count(item.messages.length,'message');
            const indices = new Set(item.messages.map(message=>message.index));
            for (const row of card.querySelectorAll('.message-row')) row.hidden = !indices.has(Number(row.dataset.index));
          }
          const droneIDs = new Set(current.map(item=>item.log.droneID));
          for (const section of document.querySelectorAll('.drone-section')) section.hidden = !droneIDs.has(section.dataset.drone);
          for (const card of groupCards) {
            const group = groups.get(card.dataset.group); card.hidden = !group;
            if (!group) continue;
            card.querySelector('.group-count').textContent = count(group.logs.size,'log')+' · '+count(group.messages,'message');
            for (const row of card.querySelectorAll('.group-occurrence')) row.hidden = !group.logs.has(row.dataset.log);
          }
          const otherGroups = $('other-groups');
          if (otherGroups) {
            const visible = [...otherGroups.querySelectorAll('.alert-group')].filter(card=>!card.hidden).length;
            otherGroups.hidden = !visible;
            $('other-groups-label').textContent = 'Autres messages · '+count(visible,'groupe');
            if (filters.level === 'INFO' || filters.level === 'DEBUG' || filters.query.trim()) otherGroups.open = true;
          }
          drawFamilies(current,stats); drawTimeline(current);
          $('expand-logs').textContent = cards.filter(card=>!card.hidden).every(card=>card.open) && current.length ? 'Replier les logs visibles' : 'Déplier les logs visibles';
          $('expand-logs').disabled = !current.length;
        }
        for (const [id,key] of [['drone-filter','drone'],['family-filter','family'],['level-filter','level']]) $(id).addEventListener('change',e=>{filters[key]=e.target.value;render();});
        $('report-search').addEventListener('input',e=>{filters.query=e.target.value;clearTimeout(pendingSearch);pendingSearch=setTimeout(render,100);});
        $('reset-filters').addEventListener('click',()=>{clearTimeout(pendingSearch);Object.keys(filters).forEach(key=>filters[key]='');['drone-filter','family-filter','level-filter','report-search'].forEach(id=>$(id).value='');render();});
        $('expand-logs').addEventListener('click',()=>{const visible=cards.filter(card=>!card.hidden), open=!visible.every(card=>card.open);visible.forEach(card=>card.open=open);$('expand-logs').textContent=open?'Replier les logs visibles':'Déplier les logs visibles';});
        for (const link of document.querySelectorAll('[data-open-log]')) link.addEventListener('click',()=>{const target=$(link.dataset.openLog);if(target)target.open=true;});
        let printStates=[];
        window.addEventListener('beforeprint',()=>{printStates=[...document.querySelectorAll('details')].map(node=>[node,node.open]);for(const [node] of printStates)if(!node.closest('[hidden]'))node.open=true;});
        window.addEventListener('afterprint',()=>{for(const [node,open] of printStates)node.open=open;printStates=[];});
        $('print-report').addEventListener('click',()=>{clearTimeout(pendingSearch);render();window.print();});
        const themeButton=$('theme-toggle');
        function dark(){return document.documentElement.dataset.theme?document.documentElement.dataset.theme==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches;}
        function themeLabel(){themeButton.textContent=dark()?'Thème clair':'Thème sombre';}
        themeButton.addEventListener('click',()=>{document.documentElement.dataset.theme=dark()?'light':'dark';themeLabel();});
        themeLabel(); render();
        ['filter-controls','report-actions','expand-logs'].forEach(id=>$(id).hidden=false);
      } catch (error) {
        const notice=el('p','notice','Les filtres interactifs n’ont pas pu être chargés. Le rapport complet reste disponible ci-dessous.');
        document.querySelector('.scope-bar').append(notice);
        for (const node of document.querySelectorAll('.log-card,.drone-section,.alert-group,.message-row,.group-occurrence')) node.hidden=false;
      }
    })();
    """#
}
