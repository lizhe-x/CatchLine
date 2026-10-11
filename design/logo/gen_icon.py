"""Generates the CatchLine logo SVGs (python3 design/logo/gen_icon.py).

Four tilted language tiles, A and 中 large with arrows turning between them.
Writes catchline.svg (full-bleed, iOS), catchline-rounded.svg (web favicon)
and catchline-maskable.svg (PWA maskable: artwork inside the 80% safe zone).
"""
import math, os
LAT="'SF Pro Rounded','SF Pro Display','Helvetica Neue',Arial,sans-serif"
ZH="'PingFang SC','Hiragino Sans GB',sans-serif"
JA="'Hiragino Sans','Hiragino Kaku Gothic ProN',sans-serif"
GRAD='''<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1F4A4E"/><stop offset="1" stop-color="#123236"/></linearGradient></defs>'''
WHITE,CORAL,BLUE,INK='#F4F7FB','#FF9A7A','#9DBBE3','#163B3F'
GL=[('A',LAT,800,0.74,WHITE),('中',ZH,600,0.70,CORAL),('あ',JA,700,0.68,BLUE),('Ñ',LAT,800,0.70,WHITE)]
def rr(x,y,w,h,r,sharp=()):
    # rounded rect; corners in `sharp` (tl,tr,br,bl) are square
    c=lambda k: 0 if k in sharp else r
    tl,tr,br,bl=c('tl'),c('tr'),c('br'),c('bl')
    return (f'M{x+tl},{y} H{x+w-tr} Q{x+w},{y} {x+w},{y+tr} V{y+h-br} Q{x+w},{y+h} {x+w-br},{y+h} '
            f'H{x+bl} Q{x},{y+h} {x},{y+h-bl} V{y+tl} Q{x},{y} {x+tl},{y} Z')
def glyph(i,cx,cy,s,fill=INK):
    ch,f,w,k,_=GL[i]
    return f'<text x="{cx}" y="{cy+s*0.02}" font-family="{f}" font-weight="{w}" font-size="{s*k}" fill="{fill}" text-anchor="middle" dominant-baseline="central">{ch}</text>'
def grid(x0,y0,s,g,sharps,r=None):
    r=r if r is not None else s*0.3; out=''
    for i,(dx,dy) in enumerate([(0,0),(1,0),(0,1),(1,1)]):
        x,y=x0+dx*(s+g),y0+dy*(s+g)
        out+=f'<path d="{rr(x,y,s,s,r,sharps[i])}" fill="{GL[i][4]}"/>'+glyph(i,x+s/2,y+s/2,s)
    return out
ARROW='#FFD27A'
def tile(i,cx,cy,s,rot,r=None):
    r=r if r is not None else s*0.26
    return (f'<g transform="translate({cx},{cy}) rotate({rot})">'
            f'<rect x="{-s/2}" y="{-s/2}" width="{s}" height="{s}" rx="{r}" fill="{GL[i][4]}"/>'
            + glyph(i,0,0,s) + '</g>')
def head(x,y,ang,size=13,col=ARROW):
    # filled arrowhead with tip at (x,y) pointing along ang (degrees)
    a=math.radians(ang); bx,by=x-size*math.cos(a),y-size*math.sin(a)
    px,py=-math.sin(a)*size*0.62,math.cos(a)*size*0.62
    return f'<path d="M{x:.1f},{y:.1f} L{bx+px:.1f},{by+py:.1f} L{bx-px:.1f},{by-py:.1f} Z" fill="{col}"/>'
def arc(cx,cy,R,a0,a1,w=8,col=ARROW,heads=(False,True)):
    # arc from a0 to a1 (deg, clockwise positive in SVG coords) with optional heads
    p=lambda a:(cx+R*math.cos(math.radians(a)),cy+R*math.sin(math.radians(a)))
    (x0,y0),(x1,y1)=p(a0),p(a1); large=1 if abs(a1-a0)>180 else 0; sweep=1 if a1>a0 else 0
    hs=w*1.9; trim=hs*0.75/R*180/math.pi
    b0=a0+(trim if heads[0] else 0)*(1 if a1>a0 else -1); b1=a1-(trim if heads[1] else 0)*(1 if a1>a0 else -1)
    (u0,v0),(u1,v1)=p(b0),p(b1)
    out=f'<path d="M{u0:.1f},{v0:.1f} A{R},{R} 0 {large} {sweep} {u1:.1f},{v1:.1f}" fill="none" stroke="{col}" stroke-width="{w}" stroke-linecap="round"/>'
    d=90 if a1>a0 else -90
    if heads[1]: out+=head(x1,y1,a1+d,hs,col)
    if heads[0]: out+=head(x0,y0,a0-d,hs,col)
    return out
def dbl(x0,y0,x1,y1,w=8,col=ARROW):
    a=math.degrees(math.atan2(y1-y0,x1-x0)); hs=w*1.9; L=math.hypot(x1-x0,y1-y0)
    ux,uy=(x1-x0)/L,(y1-y0)/L
    return (f'<path d="M{x0+ux*hs*0.7:.1f},{y0+uy*hs*0.7:.1f} L{x1-ux*hs*0.7:.1f},{y1-uy*hs*0.7:.1f}" stroke="{col}" stroke-width="{w}" stroke-linecap="round"/>'
            + head(x1,y1,a,hs,col)+head(x0,y0,a+180,hs,col))

ART=(tile(2,196,66,44,14)+tile(3,60,192,44,-12)+tile(0,86,98,80,-8)+tile(1,170,160,80,6)
     +arc(128,129,58,-62,-8,w=9)+arc(128,129,58,118,172,w=9))

def svg(rx=0,scale=1.0):
    art=ART if scale==1 else f'<g transform="translate(128,128) scale({scale}) translate(-128,-128)">{ART}</g>'
    return (f'<svg width="1024" height="1024" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">{GRAD}'
            f'<rect width="256" height="256" rx="{rx}" fill="url(#bg)"/>{art}</svg>\n')

here=os.path.dirname(os.path.abspath(__file__))
for name,body in {'catchline.svg':svg(),'catchline-rounded.svg':svg(rx=56),'catchline-maskable.svg':svg(scale=0.8)}.items():
    open(os.path.join(here,name),'w').write(body)
