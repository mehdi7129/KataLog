import Foundation

enum ReportInteraction {
    static let script = #"""
    (() => {
      'use strict';
      const rank = level => ({EMERGENCY:8,ALERT:7,CRITICAL:6,ERROR:5,WARNING:4,WARN:4,NOTICE:3,INFO:2,DEBUG:1}[level] || 0);
      const norm = value => String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLocaleLowerCase('fr');
      const finite = value => Number.isFinite(value) ? Math.max(0, value) : 0;
      const validFlight = value => Number.isFinite(value) && value >= 0;
      const provisional = log => log.identityProvisional ?? (!String(log.droneID||'').trim() || /^(card:|unknown:)/.test(String(log.droneID).trim().toLowerCase()));
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
          return [{log,messages,messageScoped:hasMessageFilter || (log.selectionIncludesEvents ?? log.selectionIncludesFailsafe) === false,
            includeFailsafe:!hasMessageFilter && log.selectionIncludesFailsafe !== false,hasMessageFilter}];
        });
      }
      function assessment(item) {
        const {log,messages,includeFailsafe,messageScoped,hasMessageFilter} = item;
        if (!hasMessageFilter && log.signalAssessment) return log.signalAssessment;
        let maximum=0,level=null,primaryText=null,occurrenceCount=0,eventCount=0,untranslatedEventCount=0,uncertain=false,failsafeMessage=false;
        function observe(priority,sourceLevel,text) {
          if(priority<4)return;
          occurrenceCount++;
          if(priority>maximum){maximum=priority;level=sourceLevel;primaryText=text;}
        }
        for(const message of messages) {
          const sourceLevel=String(message.level||'UNKNOWN').toUpperCase(), priority=rank(sourceLevel), text=message.text||message.title||'';
          const failsafe=/\bfailsafe activated\b/i.test(text);
          failsafeMessage ||= failsafe; uncertain ||= priority===0;
          observe(Math.max(priority,message.isAlert||failsafe||text.toUpperCase().includes('[ALARM]')?4:0),priority?sourceLevel:null,text||null);
        }
        if(!messageScoped)for(const event of log.events||[]) {
          eventCount++;
          const translated=event.translationStatus==='translated';if(!translated)untranslatedEventCount++;
          const levels=[event.internalLevelName,event.externalLevelName].filter(Boolean);
          if(!levels.length)levels.push(event.level||'UNKNOWN');
          const sourceLevel=levels.map(value=>String(value).toUpperCase()).sort((a,b)=>rank(b)-rank(a))[0],priority=rank(sourceLevel);
          uncertain ||= priority===0;
          observe(priority,priority?sourceLevel:null,translated&&event.message?event.message:'Événement PX4 '+String(event.eventID??'?'));
        }
        if(includeFailsafe&&log.failsafeObserved&&!failsafeMessage){
          occurrenceCount++;if(maximum<4){maximum=4;level=null;primaryText='Failsafe observé';}
        }
        const complete=log.status==='ok'&&!uncertain&&(messageScoped||log.eventsComplete===true||Array.isArray(log.events));
        const state=maximum>=6?'critical':maximum>=5?'error':maximum>=4?'warning':complete?'none':'unknown';
        return {state,level,primaryText,occurrenceCount,eventCount,untranslatedEventCount};
      }
      const assessmentLabel = value => ({critical:'Signal critique',error:'Erreur à vérifier',warning:'Avertissement',none:'Aucune alerte détectée',unknown:'Niveau indéterminé'}[value.state]||'Niveau indéterminé');
      const assessmentTone = value => ({critical:'red',error:'orange',warning:'yellow'}[value.state]||'neutral');
      const assessmentReason = value => value.primaryText || (value.state==='none'?'Aucune alerte classée dans les données évaluées':value.state==='unknown'?'Données insuffisantes pour établir le niveau':'Signal enregistré dans les données évaluées');
      const withAlerts = item => item.log.status !== 'error' && (item.messages.some(m => m.isAlert) || (item.includeFailsafe && item.log.failsafeObserved));
      function statistics(selected) {
        const valid = selected.filter(item => item.log.status !== 'error');
        const flight = valid.filter(item => validFlight(item.log.flightSeconds));
        return {
          logCount:selected.length, droneCount:new Set(selected.map(item => item.log.droneID)).size,
          scannedDroneCount:new Set(selected.filter(item => !provisional(item.log)).map(item => item.log.droneID)).size,
          provisionalDroneCount:new Set(selected.filter(item => provisional(item.log)).map(item => item.log.droneID)).size,
          validLogCount:valid.length, durationSeconds:valid.reduce((sum,item) => sum + finite(item.log.durationSeconds),0),
          flightSeconds:flight.length ? flight.reduce((sum,item) => sum + item.log.flightSeconds,0) : null,
          flightLogCount:flight.length,
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
      function groupCounts(selected) {
        const groups = new Map();
        for (const {log,messages} of selected) for (const message of messages) {
          if (!groups.has(message.groupKey)) groups.set(message.groupKey,{messages:0,logs:new Set(),byLog:new Map()});
          const group=groups.get(message.groupKey);
          group.messages++; group.logs.add(log.id);
          group.byLog.set(log.id,(group.byLog.get(log.id)||0)+1);
        }
        return groups;
      }
      function pageWindow(values, index=0, size=100) {
        const limit = Number.isInteger(size) && size > 0 ? size : 100;
        const last = Math.max(0, Math.ceil(values.length/limit)-1);
        const page = Math.max(0,Math.min(last,Number.isInteger(index)?index:0));
        const start=page*limit, end=Math.min(values.length,start+limit);
        return {items:values.slice(start,end),index:page,start,end,total:values.length,hasPrevious:page>0,hasNext:end<values.length};
      }
      if (typeof module !== 'undefined' && module.exports) module.exports = {selectLogs,statistics,familyCounts,dailyCounts,dayKey,groupCounts,pageWindow,assessment,assessmentLabel,assessmentTone};
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
        let current = [], pendingSearch, currentByLog=new Map(), currentGroups=new Map(), printing=false;
        const logByID = new Map(data.logs.map(log=>[log.id,log]));
        const cardByID = new Map(cards.map(card=>[card.dataset.log,card]));
        const detailPages = new Map(), pageSize=100;
        const empty = (container,text) => container.replaceChildren(el('p','empty-state',text));
        const table = headers => {
          const wrap=el('div','table-wrap'), node=el('table'), head=el('thead'), tr=el('tr'), body=el('tbody');
          for(const label of headers)tr.append(el('th','',label));
          head.append(tr);node.append(head,body);wrap.append(node);return {wrap,node,body};
        };
        function detailWindow(card,values) {
          if(printing)return {items:values,start:0,end:values.length,total:values.length,index:0,hasPrevious:false,hasNext:false};
          const page=pageWindow(values,detailPages.get(card)||0,pageSize);detailPages.set(card,page.index);return page;
        }
        function pager(card,page,noun,refresh) {
          const controls=el('div','detail-pagination');
          controls.style.cssText='display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin:12px 0';
          const label=el('span','muted',page.total ? integer.format(page.start+1)+'–'+integer.format(page.end)+' / '+count(page.total,noun) : 'Aucun '+noun+' pour ces filtres.');
          label.setAttribute('role','status');
          controls.append(label);
          if(!printing&&page.total>pageSize){
            const changePage=(index,direction)=>{
              const active=document.activeElement,restoreFocus=active?.dataset.detailPage===direction&&card.contains(active);
              detailPages.set(card,index);refresh(card);
              if(restoreFocus){
                const buttons=[...card.querySelectorAll('.detail-pagination button')];
                const target=buttons.find(node=>node.dataset.detailPage===direction&&!node.disabled)||buttons.find(node=>!node.disabled);
                target?.focus({preventScroll:true});
              }
            };
            const previous=button('Précédent',()=>changePage(page.index-1,'previous'));previous.disabled=!page.hasPrevious;previous.dataset.detailPage='previous';
            const next=button('Suivant',()=>changePage(page.index+1,'next'));next.disabled=!page.hasNext;next.dataset.detailPage='next';
            previous.setAttribute('aria-label','Page précédente des '+noun+' du détail');next.setAttribute('aria-label','Page suivante des '+noun+' du détail');
            controls.append(previous,next,el('small','muted','Toutes les données restent dans ce rapport. L’impression couvre la sélection intégrale.'));
          }
          return controls;
        }
        function clearDetail(card,selector) {const target=card.querySelector(selector);if(target){target.replaceChildren();target.hidden=true;}}
        function hydrateLog(card) {
          const target=card.querySelector('.lazy-message-table'), item=currentByLog.get(card.dataset.log);
          if(!target)return;
          if(!card.open||card.hidden||!item){clearDetail(card,'.lazy-message-table');return;}
          const page=detailWindow(card,item.messages), content=table(['t (s)','Niveau','Famille','Message source']);content.node.className='message-table';
          for(const message of page.items){
            const row=el('tr','message-row');row.dataset.index=String(message.index);
            const tone=rank(message.level)>=5?'danger':rank(message.level)>=4?'warning':'neutral';
            const level=el('td'),family=el('td','',message.family);level.append(el('span','severity '+tone,message.level));
            if(message.sourceFamily)family.append(el('small','','Manuelle · détectée : '+message.sourceFamily));
            row.append(el('td','mono',Number.isFinite(message.timeSeconds)?message.timeSeconds.toFixed(2):'non disponible'),level,family,el('td','raw',message.text));content.body.append(row);
          }
          target.replaceChildren(pager(card,page,'message',hydrateLog),content.wrap);target.hidden=false;
        }
        function hydrateGroup(card) {
          const target=card.querySelector('.lazy-occurrence-table'), group=currentGroups.get(card.dataset.group);
          if(!target)return;
          if(!card.open||card.hidden||!group){clearDetail(card,'.lazy-occurrence-table');return;}
          const values=[...group.byLog.keys()].sort(),page=detailWindow(card,values),content=table(['Drone','Log','Messages']);
          for(const id of page.items){
            const log=logByID.get(id),logCard=cardByID.get(id);if(!log||!logCard)continue;
            const row=el('tr','group-occurrence');row.dataset.log=id;
            const cell=el('td'),link=el('a','',log.fileName+' · '+log.date);link.href='#'+logCard.id;link.dataset.openLog=logCard.id;
            link.addEventListener('click',()=>{logCard.open=true;hydrateLog(logCard);});cell.append(link);
            row.append(el('td','',log.droneName),cell,el('td','occurrence-message-count',integer.format(group.byLog.get(id))));content.body.append(row);
          }
          target.replaceChildren(pager(card,page,'log',hydrateGroup),content.wrap);target.hidden=false;
        }
        function filterFamily(name) { filters.family = filters.family === name ? '' : name; $('family-filter').value = filters.family; render(); }
        function drawFamilies(selected,stats) {
          const values = familyCounts(selected), container = $('family-chart'), legend = $('family-legend');
          container.replaceChildren(); legend.replaceChildren();
          $('radar-scale').textContent = '0 — ' + count(stats.validLogCount,'log');
          if (!values.length) {
            empty(container,stats.failsafeLogCount ? 'Failsafe observé, sans famille d’alerte textuelle dans ce périmètre.' : 'Aucun message d’alerte textuel affiché. Consulter le badge et la couverture de chaque log.'); return;
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
        function render(resetPages=true) {
          if(resetPages)detailPages.clear();
          current = selectLogs(data.logs,filters);
          const stats = statistics(current), byLog = new Map(current.map(item=>[item.log.id,item])), groups = groupCounts(current);
          currentByLog=byLog;currentGroups=groups;
          $('stat-drones').textContent = integer.format(stats.scannedDroneCount);
          $('stat-provisional').textContent = count(stats.provisionalDroneCount,'identité')+' provisoire'+(stats.provisionalDroneCount>1?'s':'');
          $('stat-logs').textContent = integer.format(stats.logCount);
          $('stat-quality').textContent = count(stats.validLogCount,'lisible')+' · '+stats.failedLogCount+' en erreur';
          $('stat-duration').replaceChildren(document.createTextNode(decimal.format(stats.durationSeconds/60)),el('em','',' min'));
          $('stat-flight').replaceChildren(document.createTextNode(stats.flightSeconds===null?'Non disponible':decimal.format(stats.flightSeconds/60)),...(stats.flightSeconds===null?[]:[el('em','',' min')]));
          $('stat-flight-coverage').textContent = 'Calculé sur '+stats.flightLogCount+' / '+stats.logCount+' logs';
          $('stat-alerts').replaceChildren(document.createTextNode(integer.format(stats.alertLogCount)),el('em','',' / '+stats.validLogCount));
          $('stat-alert-detail').textContent = count(stats.alertMessageCount,'message')+' d’alerte'+(stats.failsafeLogCount?' · '+count(stats.failsafeLogCount,'log')+' avec failsafe':'');
          const messagesOnly=current.some(item=>item.messageScoped);
          $('assessment-scope').textContent = messagesOnly ? 'Badge limité aux messages affichés : événements PX4 et état failsafe exclus du périmètre.' : 'Badge : messages, événements PX4 disponibles et état failsafe dans le périmètre exporté.';
          const scope = [];
          if(filters.drone) scope.push($('drone-filter').selectedOptions[0].textContent);
          if(filters.family) scope.push(filters.family);
          if(filters.level) scope.push($('level-filter').selectedOptions[0].textContent);
          if(filters.query.trim()) scope.push('Recherche : '+filters.query.trim());
          if(filters.day) scope.push('Période : '+prettyDay(filters.day));
          $('filter-status').textContent = (scope.length?scope.join(' · '):'Tout le périmètre exporté')+' — '+stats.logCount+' / '+data.logs.length+' fichiers · '+count(stats.messageCount,'message');
          $('reset-filters').disabled = !scope.length;
          $('group-summary').textContent = count(groups.size,'groupe')+' · '+count(stats.messageCount,'message');
          $('groups-empty').hidden = groups.size>0; $('logs-empty').hidden = current.length>0;
          for (const card of cards) {
            const item = byLog.get(card.dataset.log); card.hidden = !item;
            if (!item) {clearDetail(card,'.lazy-message-table');continue;}
            card.querySelector('.visible-message-count').textContent = count(item.messages.length,'message');
            const signal=assessment(item),badge=card.querySelector('.log-assessment');
            badge.textContent=assessmentLabel(signal);badge.className='log-assessment '+assessmentTone(signal);
            badge.title=(item.messageScoped?'Messages affichés uniquement. ':'')+assessmentReason(signal)+'. '+count(signal.occurrenceCount,'signal')+' observé'+(signal.occurrenceCount>1?'s':'')+'. '+count(signal.untranslatedEventCount,'événement')+' sans traduction.';
            const description=card.querySelector('.assessment-description'),primary=card.querySelector('.assessment-primary'),counts=card.querySelector('.assessment-counts');
            if(description)description.textContent=badge.title;
            if(primary)primary.textContent=assessmentReason(signal);
            if(counts)counts.textContent=count(signal.occurrenceCount,'occurrence')+' de signaux · '+count(signal.eventCount,'événement')+' observé'+(signal.eventCount>1?'s':'')+' · '+signal.untranslatedEventCount+' sans traduction.';
            hydrateLog(card);
          }
          const droneIDs = new Set(current.map(item=>item.log.droneID));
          for (const section of document.querySelectorAll('.drone-section')) section.hidden = !droneIDs.has(section.dataset.drone);
          for (const card of groupCards) {
            const group = groups.get(card.dataset.group); card.hidden = !group;
            if (!group) {clearDetail(card,'.lazy-occurrence-table');continue;}
            card.querySelector('.group-count').textContent = count(group.logs.size,'log')+' · '+count(group.messages,'message');
            hydrateGroup(card);
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
        cards.forEach(card=>card.addEventListener('toggle',()=>hydrateLog(card)));
        groupCards.forEach(card=>card.addEventListener('toggle',()=>hydrateGroup(card)));
        $('expand-logs').addEventListener('click',()=>{const visible=cards.filter(card=>!card.hidden), open=!visible.every(card=>card.open);visible.forEach(card=>{card.open=open;hydrateLog(card);});$('expand-logs').textContent=open?'Replier les logs visibles':'Déplier les logs visibles';});
        for (const link of document.querySelectorAll('[data-open-log]')) link.addEventListener('click',()=>{const target=$(link.dataset.openLog);if(target)target.open=true;});
        let printStates=[],printPages=new Map();
        window.addEventListener('beforeprint',()=>{
          if(printing)return;clearTimeout(pendingSearch);render(false);
          printPages=new Map(detailPages);printStates=[...document.querySelectorAll('details')].map(node=>[node,node.open]);printing=true;
          for(const [node] of printStates)if(!node.closest('[hidden]'))node.open=true;
          cards.forEach(hydrateLog);groupCards.forEach(hydrateGroup);
        });
        window.addEventListener('afterprint',()=>{
          if(!printing)return;printing=false;detailPages.clear();for(const [card,index] of printPages)detailPages.set(card,index);
          for(const [node,open] of printStates)node.open=open;printStates=[];printPages.clear();render(false);
        });
        $('print-report').addEventListener('click',()=>{clearTimeout(pendingSearch);render(false);window.print();});
        const themeButton=$('theme-toggle');
        function dark(){return document.documentElement.dataset.theme?document.documentElement.dataset.theme==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches;}
        function themeLabel(){themeButton.textContent=dark()?'Thème clair':'Thème sombre';}
        themeButton.addEventListener('click',()=>{document.documentElement.dataset.theme=dark()?'light':'dark';themeLabel();});
        themeLabel(); render();
        ['filter-controls','report-actions','expand-logs'].forEach(id=>$(id).hidden=false);
      } catch (error) {
        const notice=el('p','notice','Les filtres interactifs n’ont pas pu être chargés. Le rapport complet reste disponible ci-dessous.');
        document.querySelector('.scope-bar').append(notice);
        // noscript is raw text when page scripts are enabled. These fragments
        // were escaped by the renderer; parse only that trusted fallback, never
        // a message or a value from the JSON payload as markup.
        for(const fallback of document.querySelectorAll('noscript.message-fallback,noscript.occurrence-fallback')){
          const parsed=new DOMParser().parseFromString(fallback.textContent,'text/html');
          fallback.replaceWith(...[...parsed.body.childNodes].map(node=>document.importNode(node,true)));
        }
        document.querySelectorAll('.lazy-message-table,.lazy-occurrence-table').forEach(node=>node.remove());
        for (const node of document.querySelectorAll('.log-card,.drone-section,.alert-group,.message-row,.group-occurrence')) node.hidden=false;
      }
    })();
    """#
}
