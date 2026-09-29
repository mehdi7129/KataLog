"""KataLog UI v2: deterministic fictional boards, never real-log screenshots.

All values below are fabricated. This renderer reads no ULog, application
library, report or user preferences. Only fonts are read from the system.
"""
from pathlib import Path
from functools import lru_cache
import math
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SCALE = 2

# Public design fixture. Do not replace these values with operational fleet data.
DEMO = {
    "source": "LOGS DE DÉMONSTRATION",
    "name": "DEMO_01",
    "durations": [180, 240, 300, 360, 420, 480, 540, 600, 660],
    "dates": [f"{day:02d}/01" for day in range(10, 19)],
    "profile": [3, 1, 1, 1, 1],
}

@lru_cache(maxsize=100)
def font(size=14, weight='Regular', mono=False):
    f = ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf' if mono else '/System/Library/Fonts/SFNS.ttf', round(size*SCALE))
    if not mono:
        f.set_variation_by_name(weight)
    return f

class Board:
    def __init__(self, dark, page):
        self.dark, self.page = dark, page
        self.c = dict(bg='#0B0B0B', side='#111111', card='#191919', raised='#242424', line='#303030', text='#F3F3F1', sub='#AAAAAA', faint='#929292', mint='#81CBB7', red='#F2948C', amber='#D8B071') if dark else dict(bg='#F7F7F5', side='#EEEEEC', card='#FFFFFF', raised='#F2F2EF', line='#E2E2DE', text='#171717', sub='#646464', faint='#6B6B6B', mint='#237E68', red='#BD4A41', amber='#966419')
        self.im = Image.new('RGB',(1600*SCALE,1040*SCALE),self.c['bg'])
        self.d=ImageDraw.Draw(self.im)

    def r(self,box,fill=None,r=0,outline=None,width=1):
        self.d.rounded_rectangle(tuple(round(n*SCALE) for n in box),radius=round(r*SCALE),fill=fill,outline=outline,width=round(width*SCALE))

    def line(self,points,color=None,width=1):
        self.d.line([(round(x*SCALE),round(y*SCALE)) for x,y in points],fill=color or self.c['line'],width=round(width*SCALE),joint='curve')

    def dot(self,x,y,color,r=3):
        self.d.ellipse(tuple(round(v*SCALE) for v in (x-r,y-r,x+r,y+r)),fill=color)

    def t(self,x,y,text,size=14,color=None,weight='Regular',anchor='lt',mono=False):
        self.d.text((round(x*SCALE),round(y*SCALE)),text,font=font(size,weight,mono),fill=color or self.c['text'],anchor=anchor)

    def panel(self,x,y,w,h):
        self.r((x,y,x+w,y+h),self.c['card'],18,self.c['line'])

    def tag(self,x,y,label,color=None):
        width=self.d.textlength(label,font=font(11,'Medium'))/SCALE+20
        self.r((x,y,x+width,y+24),self.c['raised'],7)
        self.t(x+10,y+6,label,11,color or self.c['sub'],'Medium')
        return width

    def icon(self,x,y,name,color=None,s=17):
        c=color or self.c['sub']
        if name=='grid':
            for dx in (0,10):
                for dy in (0,10): self.r((x+dx,y+dy,x+dx+6,y+dy+6),None,1.5,c)
        elif name=='drone':
            for dx,dy in ((0,0),(12,0),(0,12),(12,12)):
                self.d.ellipse(tuple(round(v*SCALE) for v in (x+dx,y+dy,x+dx+5,y+dy+5)),outline=c,width=SCALE)
            self.line([(x+3,y+3),(x+14,y+14)],c)
            self.line([(x+14,y+3),(x+3,y+14)],c)
        elif name=='wave':
            self.line([(x,y+9),(x+4,y+9),(x+7,y+2),(x+10,y+16),(x+13,y+9),(x+18,y+9)],c,1.4)
        elif name=='doc':
            self.r((x+2,y,x+15,y+18),None,2,c)
            for dy in (6,10,14): self.line([(x+5,y+dy),(x+12,y+dy)],c)
        elif name=='search':
            self.d.ellipse(tuple(round(v*SCALE) for v in (x,y,x+11,y+11)),outline=c,width=SCALE)
            self.line([(x+10,y+10),(x+16,y+16)],c,1.5)
        elif name=='chevron': self.line([(x,y),(x+4,y+4),(x,y+8)],c,1.5)
        elif name=='down': self.line([(x,y),(x+4,y+4),(x+8,y)],c,1.3)
        elif name=='folder':
            self.line([(x,y+4),(x+6,y+4),(x+8,y+7),(x+18,y+7),(x+18,y+18),(x,y+18),(x,y+4)],c,1.5)
        elif name=='sun':
            self.d.ellipse(tuple(round(v*SCALE) for v in (x+5,y+5,x+13,y+13)),outline=c,width=SCALE)
            for i in range(8):
                a=2*math.pi*i/8
                self.line([(x+9+7*math.cos(a),y+9+7*math.sin(a)),(x+9+10*math.cos(a),y+9+10*math.sin(a))],c)

    def chrome(self):
        c=self.c
        self.r((0,0,204,1040),c['side'])
        self.line([(204,0),(204,1040)])
        for x,color in ((25,'#FA6E63'),(46,'#EDBD50'),(67,'#5CCB73')):self.dot(x,28,color,5.5)
        # restrained line mark
        for dx,dy in ((0,0),(10,0),(0,10),(10,10)):
            self.r((24+dx,77+dy,30+dx,83+dy),c['text'],1.5)
        self.t(55,75,'kataLOG',22,weight='Semibold')
        self.t(25,112,'Analyse de flotte',12,c['sub'])
        self.t(25,167,'BIBLIOTHÈQUE',10,c['faint'],'Semibold')
        labels=[('Vue d’ensemble','grid'),('Drones','drone'),('Alertes','wave'),('Rapports','doc')]
        active=0 if self.page=='overview' else 2
        for i,(label,icon) in enumerate(labels):
            y=195+i*45
            if i==active:self.r((12,y,192,y+37),c['raised'],9)
            self.icon(25,y+10,icon,c['text'] if i==active else c['sub'])
            self.t(54,y+12,label,12,c['text'] if i==active else c['sub'],'Medium' if i==active else 'Regular')
        self.line([(24,398),(180,398)])
        self.t(25,419,'VOTRE SOURCE',10,c['faint'],'Semibold')
        self.icon(25,450,'folder')
        self.t(54,451,DEMO['source'],11,c['sub'],'Medium')
        self.t(54,473,'1 drone identifié',11,c['faint'])
        self.r((16,904,188,986),c['raised'],12)
        self.dot(32,924,c['mint'])
        self.t(43,918,'Données fictives',11,weight='Medium')
        self.t(30,942,'Échantillon de 9 logs',11,c['sub'])
        self.t(30,961,'Aperçu de conception',10,c['faint'])
        self.t(25,1011,'v0.2 · PROTOTYPE',9,c['faint'])
        # utility bar
        self.line([(204,56),(1600,56)])
        self.icon(244,21,'folder',c['faint'],14)
        self.t(274,24,'Espace local',12,c['sub'])
        self.t(348,24,'/',12,c['faint'])
        self.t(367,24,DEMO['source'],12,c['text'],'Medium')
        self.tag(1400,16,'Échantillon')
        self.icon(1529,19,'sun',c['text'])
        self.t(244,90,'Vue d’ensemble' if self.page=='overview' else 'Alertes',32,weight='Semibold')
        self.t(244,134,'Du 10 au 18 janvier 2026 · démonstration' if self.page=='overview' else 'Retrouver un signal, comprendre son contexte.',13,c['sub'])
        self.r((1380,92,1560,130),c['text'],9)
        self.icon(1395,101,'folder',c['bg'])
        self.t(1422,104,'Choisir un dossier',12,c['bg'],'Semibold')
        self.t(244,1015,'Aperçu de conception · données entièrement fictives · aucun log de flotte utilisé',11,c['faint'])

    def coverage(self):
        c=self.c
        self.line([(244,178),(1560,178)])
        self.line([(244,251),(1560,251)])
        entries=[(244,'1','drone documenté'),(484,'9','enregistrements'),(760,'63 min','durée enregistrée'),(1136,'6 / 9','logs avec WARN / ERROR')]
        for x,value,label in entries:
            self.t(x,192,value,25,weight='Medium')
            self.t(x,224,label,11,c['sub'])
        for x in (452,728,1104):self.line([(x,196),(x,233)])

    def overview(self):
        c=self.c
        self.coverage()
        self.panel(244,278,854,342)
        self.t(268,301,'À examiner',16,weight='Semibold')
        self.tag(961,294,'Failsafe',c['red'])
        self.dot(274,349,c['red'],4)
        self.t(287,342,DEMO['name'] + '  /  18 JANV. 2026',11,c['sub'],'Medium')
        self.t(268,369,'Communication interrompue',28,weight='Semibold')
        self.t(268,410,'Perte Wi-Fi suivie d’une alarme COMMUNICATION_FENCING.',13,c['sub'])
        # event sequence
        self.line([(284,458),(1043,458)],c['line'],1.4)
        for x,label,desc,col in ((284,'Perte Wi-Fi','Lien interrompu',c['sub']),(619,'Heartbeat absent','Timeout GCS',c['sub']),(954,'Alarme fencing','Failsafe observé',c['red'])):
            self.dot(x,458,c['card'],7)
            self.dot(x,458,col,3)
            self.t(x-2,473,label,12,c['text'],'Medium')
            self.t(x-2,493,desc,11,c['sub'])
        self.r((262,541,1080,602),c['raised'],10)
        self.dot(281,570,c['amber'],4)
        self.t(299,554,'Récurrence batterie · lecture SMBus',13,weight='Medium')
        self.t(299,577,'3 logs concernés · 6 messages ERROR',11,c['sub'])
        self.t(1029,566,'Explorer',11,c['sub'],'Medium',anchor='rt')
        self.icon(1044,568,'chevron',c['sub'])
        self.radar()
        self.table_overview()
        self.history()

    def radar(self):
        c=self.c
        self.panel(1116,278,444,342)
        self.t(1140,301,'Profil des alertes',16,weight='Semibold')
        self.t(1140,329,'Logs concernés par type · échelle 0–9',11,c['sub'])
        cx,cy,r=1338,470,88
        def pt(i,v):
            a=-math.pi/2+math.pi*2*i/5
            return cx+math.cos(a)*r*v,cy+math.sin(a)*r*v
        for k in (1/3,2/3,1):self.line([pt(i,k) for i in range(5)]+[pt(0,k)],c['line'])
        for i in range(5):self.line([(cx,cy),pt(i,1)],c['line'])
        vals=DEMO['profile']
        points=[pt(i,v/9) for i,v in enumerate(vals)]
        self.d.polygon([(round(x*SCALE),round(y*SCALE)) for x,y in points],fill='#253A34' if self.dark else '#DDEDE6')
        self.line(points+[points[0]],c['mint'],2)
        for x,y in points:self.dot(x,y,c['mint'],3)
        for i,label in enumerate(('Batterie  3','Wi-Fi  1','XBee  1','Capteurs  1','Failsafe  1')):
            x,y=pt(i,1.32)
            self.t(x,y,label,11,c['sub'],'Medium',anchor='mm')
        for value in (3,6,9):self.t(cx+5,cy-r*value/9,str(value),9,c['faint'])
        self.t(1140,587,'Un log peut relever de plusieurs types.',11,c['sub'])

    def table_overview(self):
        c=self.c
        self.panel(244,638,854,343)
        self.t(268,663,'Alertes repérées',16,weight='Semibold')
        self.t(1074,669,'4 groupes illustrés',11,c['sub'],anchor='rt')
        self.t(268,697,'Qualification à confirmer à partir des messages et des courbes.',11,c['sub'])
        for x,label in ((268,'SIGNAL'),(702,'FAMILLE'),(872,'NIVEAU'),(1066,'LOGS')):
            self.t(x,738,label,10,c['faint'],'Medium',anchor='rt' if label=='LOGS' else 'lt')
        self.line([(268,758),(1074,758)])
        rows=[('Perte de communication Wi-Fi','Wifi link lost · heartbeat GCS absent','Communication','ERROR','1',c['red']),('Lecture batterie SMBus','SMBus read error: -1','Batterie','ERROR','3',c['amber']),('Perte de lien XBee','XBee link lost','Communication','WARN','1',c['amber']),('Calibration accéléromètre','Accel 0 inconsistent','Capteurs','WARN','1',c['amber'])]
        for i,(title,sub,family,level,count,col) in enumerate(rows):
            y=773+i*50
            self.dot(274,y+6,col,3)
            self.t(286,y,title,12,weight='Medium')
            self.t(286,y+20,sub,10,c['sub'],mono=True)
            self.t(702,y+10,family,11,c['sub'])
            self.tag(872,y+1,level,c['sub'])
            self.t(1066,y+10,count,12,weight='Medium',anchor='rt')

    def history(self):
        c=self.c
        self.panel(1116,638,444,343)
        self.t(1140,663,'Historique',16,weight='Semibold')
        self.t(1140,697,'9 enregistrements · ordre chronologique',11,c['sub'])
        durations=DEMO['durations']
        dates=DEMO['dates']
        for i,(duration,date) in enumerate(zip(durations,dates)):
            x=1153+i*44
            height=duration/max(durations)*91
            self.r((x-9,836-height,x+9,836),c['raised'],4)
            col=c['red'] if i==8 else c['sub'] if i in (0,5) else c['amber']
            self.r((x-9,836-height,x+9,840-height),col,2)
            self.t(x,852,date,9,c['sub'],anchor='mt')
        self.t(1140,882,'Hauteur des barres = durée enregistrée',10,c['sub'])
        self.line([(1140,909),(1536,909)])
        self.dot(1144,934,c['red'])
        self.t(1155,926,'Dernier log · 18 janvier 2026',12,weight='Medium')
        self.t(1155,948,'11 min · un failsafe fictif',11,c['sub'])

    def alerts(self):
        c=self.c
        # filters are mirrored by native UI (search, family, PX4 level).
        self.r((244,177,756,217),c['card'],10,c['line'])
        self.icon(258,189,'search',c['faint'])
        self.t(286,190,'Rechercher un signal ou un message brut…',13,c['faint'])
        for x,w,label in ((770,213,'Toutes les familles'),(997,177,'Tous les niveaux')):
            self.r((x,177,x+w,217),c['card'],10,c['line'])
            self.t(x+13,190,label,12)
            self.icon(x+w-22,194,'down')
        self.t(1200,190,'Réinitialiser',12,c['sub'])
        self.t(244,241,'4 groupes illustrés',12,weight='Medium')
        self.t(390,241,'·  1 drone fictif  ·  9 logs de démonstration',12,c['sub'])
        # selectable table
        self.panel(244,275,832,706)
        self.t(268,300,'Messages regroupés',16,weight='Semibold')
        self.tag(925,294,'4 résultats')
        for x,label in ((268,'SIGNAL / FAMILLE'),(762,'LOGS'),(860,'MESSAGES'),(1007,'NIVEAU')):
            self.t(x,352,label,10,c['faint'],'Medium',anchor='rt' if x>700 else 'lt')
        self.line([(268,373),(1052,373)])
        data=[('Perte de communication Wi-Fi','Communication · 18 janvier 2026',1,4,'ERROR',c['red']),('Lecture batterie SMBus','Batterie · janvier 2026',3,6,'ERROR',c['amber']),('Perte de lien XBee','Communication · 12 janvier 2026',1,1,'WARN',c['amber']),('Calibration accéléromètre','Capteurs · 11 janvier 2026',1,1,'WARN',c['amber'])]
        for i,(title,sub,logs,messages,level,col) in enumerate(data):
            y=393+i*78
            if i==0:self.r((258,y-7,1062,y+58),c['raised'],10)
            self.dot(275,y+14,col,4)
            self.t(293,y+1,title,13,weight='Medium')
            self.t(293,y+25,sub,11,c['sub'])
            self.t(757,y+15,str(logs),13,anchor='rt')
            self.t(849,y+15,str(messages),13,anchor='rt')
            self.tag(950,y+6,level)
        self.line([(268,718),(1052,718)])
        self.icon(270,749,'doc')
        self.t(300,749,'Chaque groupe conserve ses messages source.',13,weight='Medium')
        self.t(300,775,'Les répétitions sont regroupées pour faciliter la lecture.',12,c['sub'])
        self.t(300,797,'La sélection à droite montre le contexte et les preuves.',12,c['sub'])
        self.r((268,856,1052,952),c['raised'],12)
        self.t(286,875,'COUVERTURE DE CET APERÇU',10,c['faint'],'Semibold')
        self.t(286,899,'Messages texte et failsafe observés dans l’échantillon.',12)
        self.t(286,922,'L’analyse détaillée GPS, propulsion et batterie reste à connecter.',11,c['sub'])
        # persistent inspector
        self.panel(1094,275,466,706)
        self.dot(1120,307,c['red'],4)
        self.t(1133,300,'À EXAMINER',10,c['red'],'Semibold')
        self.t(1118,336,'Perte de communication',21,weight='Semibold')
        self.t(1118,364,'Wi-Fi',21,weight='Semibold')
        self.t(1118,405,DEMO['name'] + ' · 18 janvier 2026',12,c['sub'])
        self.tag(1118,432,'1 log')
        self.tag(1188,432,'4 messages ERROR')
        self.line([(1118,482),(1536,482)])
        self.t(1118,505,'Séquence observée',14,weight='Semibold')
        self.line([(1125,548),(1125,650)],c['line'],1.5)
        for i,(title,sub,col) in enumerate((('Lien Wi-Fi perdu','Wifi link lost',c['sub']),('Heartbeat GCS absent','Timeout waiting for GCS heartbeat',c['sub']),('Alarme de communication','COMMUNICATION_FENCING',c['red']))):
            y=542+i*51
            self.dot(1125,y+8,c['card'],6)
            self.dot(1125,y+8,col,3)
            self.t(1145,y,title,12,weight='Medium')
            self.t(1145,y+19,sub,10,c['sub'],mono=True)
        self.r((1118,705,1536,793),c['raised'],10)
        self.t(1132,721,'MESSAGE SOURCE',9,c['faint'],'Semibold')
        self.t(1132,746,'[maestro] [ALARM]',11,mono=True)
        self.t(1132,766,'COMMUNICATION_FENCING started',11,mono=True)
        self.t(1118,820,'Log d’origine',11,c['sub'])
        self.t(1118,844,'2026-01-18 / 12_00_00.ulg',12,mono=True)
        self.line([(1118,884),(1536,884)])
        self.t(1118,906,'Qualification',11,c['sub'])
        self.t(1118,930,'Cause à qualifier',12,weight='Medium')

    def save(self):
        self.chrome()
        self.overview() if self.page=='overview' else self.alerts()
        folder=ROOT/'mockups'/'public'
        folder.mkdir(parents=True, exist_ok=True)
        path=folder/f'v2-{self.page}-{"dark" if self.dark else "light"}.png'
        self.im.save(path)
        print(path)

if __name__=='__main__':
    for dark in (True,False):
        for page in ('overview','alerts'):Board(dark,page).save()
