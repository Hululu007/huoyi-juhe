try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import gzip
import html
import http.client
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date


HOST = "https://mjv011.com"
WEB = "https://chaoliu-av-tk8m.web.zaka.live"
UA = "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
COOKIE = "YES_Eighteen=IamOverEighteenYearsOld"
AGE_URL = HOST + "/zh/chinese_IamOverEighteenYearsOld/19/index.html"
JP_V = "20261005c"
PAGE = 24

MJV_CATS = [
    ("chinese", "中文字幕"),
    ("censored", "有码"),
    ("uncensored", "无码"),
    ("amateurjav", "素人"),
    ("reducing-mosaic", "无码破解"),
    ("animation", "H动画"),
    ("CensoredAnimation", "H有码动画"),
    ("UncensoredAnimation", "H无码动画"),
    ("tdAnimation", "H_3D动画"),
    ("dt", "国产自拍"),
    ("18H", "18H漫画"),
    ("doujin", "18H短篇同人"),
    ("cg", "写真图集"),
    ("cwp", "国产写真"),
    ("novel", "小说"),
]

TUKU = [
    ("pondo", "一本道 · 最新", 5),
    ("phot", "一本道 · 热门", 5),
    ("musume", "素人自拍 · 最新", 5),
    ("mhot", "素人自拍 · 热门", 5),
    ("paco", "人妻偷拍 · 最新", 5),
    ("phot2", "人妻偷拍 · 热门", 5),
    ("aidol", "女优", 4),
]

CHINESE_CATS = [
    ("企畫", "chinese_category/1/企畫"),
    ("女同性戀", "chinese_category/2/女同性戀"),
    ("獵豔、搭訕", "chinese_category/3/獵豔、搭訕"),
    ("野外・露出", "chinese_category/4/野外・露出"),
    ("偶像藝人", "chinese_category/5/偶像藝人"),
    ("其他戀物癖", "chinese_category/6/其他戀物癖"),
    ("近親相姦", "chinese_category/7/近親相姦"),
    ("巨乳癖", "chinese_category/8/巨乳癖"),
    ("情侶", "chinese_category/9/情侶"),
    ("男同性恋", "chinese_category/10/男同性恋"),
    ("花癡", "chinese_category/11/花癡"),
    ("偷窥", "chinese_category/12/偷窥"),
    ("戀腿癖", "chinese_category/13/戀腿癖"),
    ("其他", "chinese_category/14/其他"),
    ("癡漢", "chinese_category/15/癡漢"),
    ("倒追", "chinese_category/16/倒追"),
    ("奴隷", "chinese_category/17/奴隷"),
    ("跳舞", "chinese_category/18/跳舞"),
    ("雙性人", "chinese_category/19/雙性人"),
    ("姐妹", "chinese_category/20/姐妹"),
    ("通姦", "chinese_category/21/通姦"),
    ("鬼畜", "chinese_category/22/鬼畜"),
    ("學校作品", "chinese_category/23/學校作品"),
    ("惡作劇", "chinese_category/24/惡作劇"),
    ("妄想", "chinese_category/25/妄想"),
    ("殘忍畫面", "chinese_category/26/殘忍畫面"),
    ("爛醉如泥的", "chinese_category/27/爛醉如泥的"),
    ("處女", "chinese_category/28/處女"),
    ("美容院", "chinese_category/29/美容院"),
    ("性感的", "chinese_category/30/性感的"),
    ("女同接吻", "chinese_category/31/女同接吻"),
    ("運動", "chinese_category/32/運動"),
    ("瘙癢", "chinese_category/33/瘙癢"),
    ("出軌", "chinese_category/34/出軌"),
    ("處男", "chinese_category/36/處男"),
    ("蠻橫嬌羞", "chinese_category/37/蠻橫嬌羞"),
    ("觸手", "chinese_category/38/觸手"),
    ("嘔吐", "chinese_category/39/嘔吐"),
    ("拷問", "chinese_category/40/拷問"),
    ("10枚組", "chinese_category/41/10枚組"),
    ("女優合集", "chinese_category/42/女優合集"),
    ("温泉", "chinese_category/43/温泉"),
    ("M男", "chinese_category/44/M男"),
    ("原作コラボ", "chinese_category/45/原作コラボ"),
    ("16時間以上作品", "chinese_category/46/16時間以上作品"),
    ("デカチン・巨根", "chinese_category/47/デカチン・巨根"),
    ("ファン感謝・訪問", "chinese_category/48/ファン感謝・訪問"),
    ("動画", "chinese_category/49/動画"),
    ("巨尻", "chinese_category/50/巨尻"),
    ("ハーレム", "chinese_category/51/ハーレム"),
    ("日焼け", "chinese_category/52/日焼け"),
    ("早漏", "chinese_category/53/早漏"),
    ("キス・接吻", "chinese_category/54/キス・接吻"),
    ("汗だく", "chinese_category/55/汗だく"),
    ("服務生", "chinese_category/56/服務生"),
    ("高中女生", "chinese_category/57/高中女生"),
    ("女主播", "chinese_category/58/女主播"),
    ("女生", "chinese_category/59/女生"),
    ("黑人演員", "chinese_category/60/黑人演員"),
    ("痴女", "chinese_category/61/痴女"),
    ("護士", "chinese_category/62/護士"),
    ("家庭教師", "chinese_category/63/家庭教師"),
    ("母親", "chinese_category/64/母親"),
    ("女教師", "chinese_category/65/女教師"),
    ("展場女孩", "chinese_category/66/展場女孩"),
    ("女大學生", "chinese_category/67/女大學生"),
    ("賽車女郎", "chinese_category/68/賽車女郎"),
    ("妓女", "chinese_category/69/妓女"),
    ("各種職業", "chinese_category/70/各種職業"),
    ("女醫生", "chinese_category/71/女醫生"),
    ("人妻", "chinese_category/72/人妻"),
    ("白人", "chinese_category/73/白人"),
    ("千金小姐", "chinese_category/74/千金小姐"),
    ("寡婦", "chinese_category/75/寡婦"),
    ("車掌小姐", "chinese_category/76/車掌小姐"),
    ("格鬥家", "chinese_category/77/格鬥家"),
    ("姐姐", "chinese_category/78/姐姐"),
    ("新娘、嫩妻", "chinese_category/79/新娘、嫩妻"),
    ("美少女", "chinese_category/80/美少女"),
    ("秘書", "chinese_category/81/秘書"),
    ("模特兒", "chinese_category/82/模特兒"),
    ("女主人、女老板", "chinese_category/83/女主人、女老板"),
    ("明星臉", "chinese_category/84/明星臉"),
    ("女檢察官", "chinese_category/85/女檢察官"),
    ("格鬥家", "chinese_category/86/格鬥家"),
    ("義母", "chinese_category/87/義母"),
    ("教練", "chinese_category/88/教練"),
    ("伴侶", "chinese_category/89/伴侶"),
    ("亞洲女演員", "chinese_category/90/亞洲女演員"),
    ("公主", "chinese_category/91/公主"),
    ("童年朋友", "chinese_category/92/童年朋友"),
    ("黑幫成員", "chinese_category/93/黑幫成員"),
    ("角色扮演", "chinese_category/94/角色扮演"),
    ("眼鏡", "chinese_category/95/眼鏡"),
    ("泳裝", "chinese_category/96/泳裝"),
    ("校服", "chinese_category/97/校服"),
    ("迷你裙", "chinese_category/98/迷你裙"),
    ("女僕", "chinese_category/99/女僕"),
    ("旗袍", "chinese_category/100/旗袍"),
    ("學校泳裝", "chinese_category/101/學校泳裝"),
    ("水手服", "chinese_category/102/水手服"),
    ("內衣", "chinese_category/103/內衣"),
    ("體育服", "chinese_category/104/體育服"),
    ("和服・喪服", "chinese_category/105/和服・喪服"),
    ("OL", "chinese_category/106/OL"),
    ("身體意識", "chinese_category/107/身體意識"),
    ("連褲襪", "chinese_category/108/連褲襪"),
    ("空姐", "chinese_category/109/空姐"),
    ("迷你裙警察", "chinese_category/110/迷你裙警察"),
    ("裸體圍裙", "chinese_category/111/裸體圍裙"),
    ("緊身衣", "chinese_category/112/緊身衣"),
    ("制服", "chinese_category/113/制服"),
    ("泡泡襪", "chinese_category/114/泡泡襪"),
    ("女祭司", "chinese_category/115/女祭司"),
    ("貓耳女", "chinese_category/116/貓耳女"),
    ("兔女郎", "chinese_category/117/兔女郎"),
    ("猥褻穿著", "chinese_category/118/猥褻穿著"),
    ("偷看內褲", "chinese_category/119/偷看內褲"),
    ("女裝人妖", "chinese_category/120/女裝人妖"),
    ("女忍者", "chinese_category/121/女忍者"),
    ("娃娃", "chinese_category/122/娃娃"),
    ("及膝襪", "chinese_category/123/及膝襪"),
    ("女戰士", "chinese_category/124/女戰士"),
    ("巨乳", "chinese_category/127/巨乳"),
    ("貧乳・微乳", "chinese_category/128/貧乳・微乳"),
    ("熟女", "chinese_category/130/熟女"),
    ("孕婦", "chinese_category/131/孕婦"),
    ("苗條", "chinese_category/132/苗條"),
    ("胖女人", "chinese_category/133/胖女人"),
    ("無毛", "chinese_category/134/無毛"),
    ("變性者", "chinese_category/135/變性者"),
    ("高", "chinese_category/136/高"),
    ("屁股", "chinese_category/137/屁股"),
    ("嬌小的", "chinese_category/138/嬌小的"),
    ("乳房", "chinese_category/139/乳房"),
    ("肌肉", "chinese_category/140/肌肉"),
    ("超乳", "chinese_category/141/超乳"),
    ("中出", "chinese_category/142/中出"),
    ("顏射", "chinese_category/143/顏射"),
    ("自慰", "chinese_category/144/自慰"),
    ("顏射", "chinese_category/145/顏射"),
    ("肛交", "chinese_category/146/肛交"),
    ("吞精", "chinese_category/147/吞精"),
    ("打手槍", "chinese_category/148/打手槍"),
    ("放尿", "chinese_category/149/放尿"),
    ("亂交", "chinese_category/150/亂交"),
    ("口交", "chinese_category/151/口交"),
    ("飲尿", "chinese_category/152/飲尿"),
    ("排便", "chinese_category/153/排便"),
    ("乳交", "chinese_category/154/乳交"),
    ("潮吹", "chinese_category/155/潮吹"),
    ("淫語", "chinese_category/156/淫語"),
    ("69", "chinese_category/157/69"),
    ("深喉", "chinese_category/158/深喉"),
    ("拳交", "chinese_category/159/拳交"),
    ("舔陰", "chinese_category/160/舔陰"),
    ("騎乗位", "chinese_category/161/騎乗位"),
    ("按摩", "chinese_category/162/按摩"),
    ("手指插入", "chinese_category/163/手指插入"),
    ("母乳", "chinese_category/164/母乳"),
    ("足交", "chinese_category/165/足交"),
    ("食糞", "chinese_category/166/食糞"),
    ("顏面騎乘", "chinese_category/167/顏面騎乘"),
    ("肛内中出", "chinese_category/168/肛内中出"),
    ("多P", "chinese_category/169/多P"),
    ("按摩棒", "chinese_category/170/按摩棒"),
    ("緊縛", "chinese_category/171/緊縛"),
    ("跳蛋", "chinese_category/172/跳蛋"),
    ("玩具", "chinese_category/173/玩具"),
    ("糞便", "chinese_category/174/糞便"),
    ("SM", "chinese_category/175/SM"),
    ("車震", "chinese_category/176/車震"),
    ("藥物", "chinese_category/177/藥物"),
    ("強姦", "chinese_category/178/強姦"),
    ("緊縛", "chinese_category/179/緊縛"),
    ("監禁", "chinese_category/180/監禁"),
    ("灌腸", "chinese_category/181/灌腸"),
    ("鴨嘴", "chinese_category/182/鴨嘴"),
    ("插入異物", "chinese_category/183/插入異物"),
    ("輪姦", "chinese_category/184/輪姦"),
    ("拘束", "chinese_category/185/拘束"),
    ("凌辱", "chinese_category/186/凌辱"),
    ("羞恥", "chinese_category/187/羞恥"),
    ("乳液", "chinese_category/188/乳液"),
    ("催眠", "chinese_category/189/催眠"),
    ("子宮頸", "chinese_category/190/子宮頸"),
    ("女優按摩棒", "chinese_category/191/女優按摩棒"),
    ("立即口交", "chinese_category/192/立即口交"),
    ("合集", "chinese_category/193/合集"),
    ("單體作品", "chinese_category/194/單體作品"),
    ("DMM獨家", "chinese_category/195/DMM獨家"),
    ("獨立製作", "chinese_category/196/獨立製作"),
    ("局部特寫", "chinese_category/197/局部特寫"),
    ("素人", "chinese_category/198/素人"),
    ("第一人稱攝影", "chinese_category/199/第一人稱攝影"),
    ("國外進口", "chinese_category/200/國外進口"),
    ("纪录片", "chinese_category/201/纪录片"),
    ("投稿", "chinese_category/202/投稿"),
    ("數位馬賽克", "chinese_category/203/數位馬賽克"),
    ("首次亮相", "chinese_category/204/首次亮相"),
    ("經典", "chinese_category/205/經典"),
    ("薄馬賽克", "chinese_category/206/薄馬賽克"),
    ("4小時以上作品", "chinese_category/207/4小時以上作品"),
    ("介紹影片", "chinese_category/208/介紹影片"),
    ("主觀視角", "chinese_category/209/主觀視角"),
    ("高畫質", "chinese_category/210/高畫質"),
    ("戀愛", "chinese_category/211/戀愛"),
    ("戲劇", "chinese_category/212/戲劇"),
    ("複刻版", "chinese_category/213/複刻版"),
    ("限時降價", "chinese_category/214/限時降價"),
    ("故事集", "chinese_category/215/故事集"),
    ("特效", "chinese_category/216/特效"),
    ("3D", "chinese_category/217/3D"),
    ("R-18", "chinese_category/219/R-18"),
    ("R-15", "chinese_category/220/R-15"),
    ("DMM專屬", "chinese_category/221/DMM專屬"),
    ("教學", "chinese_category/222/教學"),
    ("給女性觀眾", "chinese_category/223/給女性觀眾"),
    ("恐怖", "chinese_category/224/恐怖"),
    ("合作作品", "chinese_category/225/合作作品"),
    ("パラダイスTV", "chinese_category/226/パラダイスTV"),
    ("DVDトースター", "chinese_category/227/DVDトースター"),
    ("魔法少女", "chinese_category/228/魔法少女"),
    ("假陽具", "chinese_category/229/假陽具"),
    ("順豐", "chinese_category/230/順豐"),
    ("圖片視頻（男）", "chinese_category/231/圖片視頻（男）"),
    ("AV OPEN 2014 中量級", "chinese_category/232/AV OPEN 2014 中量級"),
    ("AV OPEN 2014 超重量級", "chinese_category/233/AV OPEN 2014 超重量級"),
    ("遊戲實況", "chinese_category/234/遊戲實況"),
    ("AV OPEN 2014 ヘビー級", "chinese_category/235/AV OPEN 2014 ヘビー級"),
    ("變身女主角", "chinese_category/236/變身女主角"),
    ("AV OPEN 2015 SM/ハード部門", "chinese_category/237/AV OPEN 2015 SM/ハード部門"),
    ("AV OPEN 2015 企画部門", "chinese_category/238/AV OPEN 2015 企画部門"),
    ("AV OPEN 2015 女優部門", "chinese_category/239/AV OPEN 2015 女優部門"),
    ("AV OPEN 2015 素人部門", "chinese_category/240/AV OPEN 2015 素人部門"),
    ("AV OPEN 2015 乙女部門", "chinese_category/241/AV OPEN 2015 乙女部門"),
    ("AV OPEN 2015 熟女部門", "chinese_category/242/AV OPEN 2015 熟女部門"),
    ("AV OPEN 2015 瘋狂/戀物癖部", "chinese_category/243/AV OPEN 2015 瘋狂/戀物癖部"),
    ("推薦用於智能手機的垂直視頻", "chinese_category/244/推薦用於智能手機的垂直視頻"),
    ("V影院", "chinese_category/245/V影院"),
    ("動畫", "chinese_category/246/動畫"),
    ("行動", "chinese_category/247/行動"),
    ("黑暗系統", "chinese_category/248/黑暗系統"),
    ("迷你係列", "chinese_category/249/迷你係列"),
    ("嬌小的", "chinese_category/250/嬌小的"),
    ("浸漬", "chinese_category/251/浸漬"),
    ("AV OPEN 2016 女優部門", "chinese_category/252/AV OPEN 2016 女優部門"),
    ("AV OPEN 2016 素人部門", "chinese_category/253/AV OPEN 2016 素人部門"),
    ("AV OPEN 2016 バラエティ部門", "chinese_category/254/AV OPEN 2016 バラエティ部門"),
    ("AV OPEN 2016 劇情/紀錄片部門", "chinese_category/255/AV OPEN 2016 劇情/紀錄片部門"),
    ("AV OPEN 2016 ハード部門", "chinese_category/256/AV OPEN 2016 ハード部門"),
    ("AV OPEN 2016 瘋狂/戀物癖部門", "chinese_category/257/AV OPEN 2016 瘋狂/戀物癖部門"),
    ("AV OPEN 2016 乙女部門", "chinese_category/258/AV OPEN 2016 乙女部門"),
    ("AV OPEN 2016 企画部門", "chinese_category/259/AV OPEN 2016 企画部門"),
    ("AV OPEN 2016 人妻・熟女部門", "chinese_category/260/AV OPEN 2016 人妻・熟女部門"),
    ("婊子", "chinese_category/261/婊子"),
    ("僅限虛擬現實", "chinese_category/262/僅限虛擬現實"),
    ("AV 棒球福利", "chinese_category/263/AV 棒球福利"),
    ("時間停止", "chinese_category/264/時間停止"),
    ("漫畫雜誌", "chinese_category/265/漫畫雜誌"),
    ("搞笑喜劇", "chinese_category/266/搞笑喜劇"),
    ("男子的愛", "chinese_category/267/男子的愛"),
    ("幻想", "chinese_category/268/幻想"),
    ("AV OPEN 2017 女優部門", "chinese_category/269/AV OPEN 2017 女優部門"),
    ("AV OPEN 2017紀錄片部", "chinese_category/270/AV OPEN 2017紀錄片部"),
    ("AV OPEN 2017 フェチ部門", "chinese_category/271/AV OPEN 2017 フェチ部門"),
    ("AV OPEN 2017 乙女部門", "chinese_category/272/AV OPEN 2017 乙女部門"),
    ("AV OPEN 2017 人妻・熟女部門", "chinese_category/273/AV OPEN 2017 人妻・熟女部門"),
    ("AV OPEN 2017 マニア部門", "chinese_category/274/AV OPEN 2017 マニア部門"),
    ("AV OPEN 2017 企画部門", "chinese_category/275/AV OPEN 2017 企画部門"),
    ("AV OPEN 2017 ハード部門", "chinese_category/276/AV OPEN 2017 ハード部門"),
    ("AV OPEN 2017 素人部門", "chinese_category/277/AV OPEN 2017 素人部門"),
    ("AV OPEN 2017 ドラマ部門", "chinese_category/278/AV OPEN 2017 ドラマ部門"),
    ("經歷的告白", "chinese_category/279/經歷的告白"),
    ("變性/女性化", "chinese_category/280/變性/女性化"),
    ("集產品", "chinese_category/281/集產品"),
    ("反向強姦", "chinese_category/282/反向強姦"),
    ("反向強姦", "chinese_category/283/反向強姦"),
    ("名人朋友【特典C】合格作品", "chinese_category/284/名人朋友【特典C】合格作品"),
    ("名人朋友【特典A】合格作品", "chinese_category/285/名人朋友【特典A】合格作品"),
    ("愛情喜劇", "chinese_category/286/愛情喜劇"),
    ("僅限 FANZA 發行", "chinese_category/287/僅限 FANZA 發行"),
    ("有資格參加名人朋友活動的作品", "chinese_category/288/有資格參加名人朋友活動的作品"),
    ("愛欲", "chinese_category/289/愛欲"),
    ("高品質虛擬現實", "chinese_category/290/高品質虛擬現實"),
    ("同性戀", "chinese_category/291/同性戀"),
    ("AV OPEN 2018 女優部門", "chinese_category/292/AV OPEN 2018 女優部門"),
    ("AV OPEN 2018 企画部門", "chinese_category/293/AV OPEN 2018 企画部門"),
    ("AV OPEN 2018 素人部門", "chinese_category/294/AV OPEN 2018 素人部門"),
    ("AV OPEN 2018 瘋狂/戀物癖部門", "chinese_category/295/AV OPEN 2018 瘋狂/戀物癖部門"),
    ("AV OPEN 2018 人妻・熟女部門", "chinese_category/296/AV OPEN 2018 人妻・熟女部門"),
    ("AV OPEN 2018 ハード部門", "chinese_category/297/AV OPEN 2018 ハード部門"),
    ("AV OPEN 2018 乙女部門", "chinese_category/298/AV OPEN 2018 乙女部門"),
    ("已婚婦女/家庭主婦", "chinese_category/299/已婚婦女/家庭主婦"),
    ("連褲襪", "chinese_category/300/連褲襪"),
    ("按摩/茶點", "chinese_category/301/按摩/茶點"),
    ("乳液油", "chinese_category/302/乳液油"),
    ("年輕的妻子", "chinese_category/303/年輕的妻子"),
    ("小便/洩漏", "chinese_category/304/小便/洩漏"),
    ("保健皂", "chinese_category/305/保健皂"),
    ("極致高潮", "chinese_category/306/極致高潮"),
    ("虐待", "chinese_category/307/虐待"),
    ("M女", "chinese_category/308/M女"),
    ("職業裝", "chinese_category/309/職業裝"),
    ("背部", "chinese_category/310/背部"),
    ("不戴胸罩", "chinese_category/311/不戴胸罩"),
    ("女上司", "chinese_category/312/女上司"),
    ("洗澡", "chinese_category/313/洗澡"),
    ("乳頭滑落", "chinese_category/314/乳頭滑落"),
    ("旅行", "chinese_category/315/旅行"),
    ("奧納薩波", "chinese_category/316/奧納薩波"),
    ("蠟燭", "chinese_category/317/蠟燭"),
    ("男人噴", "chinese_category/318/男人噴"),
    ("娘・養女", "chinese_category/319/娘・養女"),
    ("面具，面具", "chinese_category/320/面具，面具"),
    ("軟體", "chinese_category/321/軟體"),
    ("面試", "chinese_category/322/面試"),
    ("宅男", "chinese_category/323/宅男"),
    ("接待員", "chinese_category/324/接待員"),
    ("沒有內褲", "chinese_category/325/沒有內褲"),
    ("酒會", "chinese_category/326/酒會"),
    ("部下・同僚", "chinese_category/327/部下・同僚"),
    ("名人", "chinese_category/328/名人"),
    ("戴綠帽子 / 戴綠帽子 / NTR", "chinese_category/329/戴綠帽子 / 戴綠帽子 / NTR"),
    ("戴綠帽子 / 戴綠帽子 / NTR", "chinese_category/330/戴綠帽子 / 戴綠帽子 / NTR"),
    ("約會", "chinese_category/331/約會"),
    ("花嫁", "chinese_category/332/花嫁"),
    ("交換/情侶交換", "chinese_category/333/交換/情侶交換"),
    ("祖父", "chinese_category/334/祖父"),
    ("姨", "chinese_category/335/姨"),
    ("鼻鉤", "chinese_category/336/鼻鉤"),
    ("運動員", "chinese_category/337/運動員"),
    ("醫院/診所", "chinese_category/338/醫院/診所"),
    ("打屁股", "chinese_category/339/打屁股"),
    ("酒店", "chinese_category/340/酒店"),
    ("女王", "chinese_category/341/女王"),
    ("瑜伽", "chinese_category/342/瑜伽"),
    ("新人陸續登場", "chinese_category/343/新人陸續登場"),
    ("白目・失神", "chinese_category/344/白目・失神"),
    ("媽媽朋友", "chinese_category/345/媽媽朋友"),
    ("啦啦隊長", "chinese_category/346/啦啦隊長"),
    ("奶奶", "chinese_category/347/奶奶"),
    ("社團活動經理", "chinese_category/348/社團活動經理"),
    ("妄想族", "chinese_category/349/妄想族"),
    ("艾曼紐", "chinese_category/350/艾曼紐"),
    ("艾曼紐", "chinese_category/351/艾曼紐"),
    ("放置", "chinese_category/352/放置"),
    ("心理驚悚片", "chinese_category/353/心理驚悚片"),
    ("切卡", "chinese_category/354/切卡"),
    ("福袋", "chinese_category/355/福袋"),
    ("最好的，綜合性的", "chinese_category/356/最好的，綜合性的"),
    ("3P、4P", "chinese_category/357/3P、4P"),
    ("女優", "chinese_category/358/女優"),
    ("藝人", "chinese_category/359/藝人"),
    ("強姦", "chinese_category/360/強姦"),
    ("湯", "chinese_category/361/湯"),
    ("凌辱", "chinese_category/362/凌辱"),
    ("偶像", "chinese_category/363/偶像"),
    ("看護師", "chinese_category/364/看護師"),
    ("奴隸", "chinese_category/365/奴隸"),
    ("風俗", "chinese_category/366/風俗"),
    ("處女之物", "chinese_category/367/處女之物"),
    ("小乳房", "chinese_category/368/小乳房"),
    ("大公雞", "chinese_category/369/大公雞"),
    ("妹", "chinese_category/370/妹"),
    ("戀物癖", "chinese_category/371/戀物癖"),
    ("示例視頻", "chinese_category/372/示例視頻"),
    ("秋季大甩賣", "chinese_category/373/秋季大甩賣"),
    ("藍光", "chinese_category/374/藍光"),
    ("出口", "chinese_category/375/出口"),
    ("動漫人物", "chinese_category/376/動漫人物"),
    ("DOD 秋季促銷第 2 部分", "chinese_category/377/DOD 秋季促銷第 2 部分"),
    ("2010年代前半（DOD）", "chinese_category/378/2010年代前半（DOD）"),
    ("光盤點播銷售", "chinese_category/379/光盤點播銷售"),
    ("AV女優", "chinese_category/380/AV女優"),
    ("設置有好處的產品", "chinese_category/381/設置有好處的產品"),
    ("Triple HAPPY 活動", "chinese_category/382/Triple HAPPY 活動"),
    ("Rena 桃園 JOKER 禮品活動", "chinese_category/383/Rena 桃園 JOKER 禮品活動"),
    ("時代劇", "chinese_category/384/時代劇"),
    ("全球媒體 40% 折扣銷售", "chinese_category/385/全球媒體 40% 折扣銷售"),
    ("Mousozoku 2021上半年進入TOP 100", "chinese_category/386/Mousozoku 2021上半年進入TOP 100"),
    ("レズビアン", "chinese_category/387/レズビアン"),
    ("BL（ボーイズラブ）", "chinese_category/388/BL（ボーイズラブ）"),
    ("8KVR", "chinese_category/389/8KVR"),
    ("妄想族30％OFF第1弾", "chinese_category/390/妄想族30％OFF第1弾"),
    ("ブランドストア30％OFF☆", "chinese_category/391/ブランドストア30％OFF☆"),
    ("ながえスタイル30％OFF", "chinese_category/392/ながえスタイル30％OFF"),
    ("MERCURY（マーキュリー）他30％OFF", "chinese_category/393/MERCURY（マーキュリー）他30％OFF"),
    ("ブランドストア30％OFF！", "chinese_category/394/ブランドストア30％OFF！"),
    ("妄想族30％OFF", "chinese_category/395/妄想族30％OFF"),
    ("BALTAN＜バルタン＞他30％OFF", "chinese_category/396/BALTAN＜バルタン＞他30％OFF"),
    ("ながえスタイル他30％OFF", "chinese_category/397/ながえスタイル他30％OFF"),
    ("台湾モデル", "chinese_category/398/台湾モデル"),
    ("AI生成作品", "chinese_category/399/AI生成作品"),
    ("アナルセックス（男の娘）", "chinese_category/400/アナルセックス（男の娘）"),
]

UNCENSORED_MAKERS = [
    ("一本道(1pondo)", "uncensored_makersr/32/一本道(1pondo)"),
    ("カリビアンコム(Caribbeancom)", "uncensored_makersr/30/カリビアンコム(Caribbeancom)"),
    ("カリビアンコムPPV", "uncensored_makersr/40/カリビアンコムPPV(Caribbeancompr)"),
    ("天然むすめ(10musume)", "uncensored_makersr/31/天然むすめ(10musume)"),
    ("HEYZO", "uncensored_makersr/17/HEYZO"),
    ("東京熱(Tokyo Hot)", "uncensored_makersr/29/東京熱(Tokyo Hot)"),
    ("ガチん娘！(Gachinco)", "uncensored_makersr/35/ガチん娘！(Gachinco)"),
    ("パコパコママ(pacopacomama)", "uncensored_makersr/36/パコパコママ(pacopacomama)"),
    ("エッチな4610", "uncensored_makersr/34/エッチな4610"),
    ("人妻斬り0930", "uncensored_makersr/38/人妻斬り0930"),
    ("エッチな0930", "uncensored_makersr/39/エッチな0930"),
    ("トリプルエックス(XXX-AV)", "uncensored_makersr/126/トリプルエックス (XXX-AV)"),
]

CG_OPTS = [
    ("全部", ""),
    ("Bejean On Line", "cg_search/all/Bejean On Line"),
    ("Bomb.tv", "cg_search/all/Bomb.tv"),
    ("DGC", "cg_search/all/DGC"),
    ("Graphis Gals", "cg_search/all/Graphis Gals"),
    ("Graphis Hatsunugi", "cg_search/all/Graphis Hatsunugi"),
    ("image.tv", "cg_search/all/image.tv"),
    ("Sabra.net", "cg_search/all/Sabra.net"),
    ("S-Cute", "cg_search/all/S-Cute"),
    ("X-City", "cg_search/all/X-City"),
    ("YS Web", "cg_search/all/YS Web"),
]

CWP_OPTS = [
    ("全部", ""),
    ("3AGirl AAA女郎", "cwp_search/all/3AGirl AAA女郎"),
    ("ROSI寫真", "cwp_search/all/ROSI寫真"),
    ("RU1MM 如壹寫真", "cwp_search/all/RU1MM 如壹寫真"),
    ("DISI第四印象", "cwp_search/all/DISI第四印象"),
]

NOVEL_OPTS = [
    ("全部", ""),
    ("學生校園", "novel_search/all/學生校園"),
    ("職場激情", "novel_search/all/職場激情"),
    ("經驗故事", "novel_search/all/經驗故事"),
    ("暴力虐待", "novel_search/all/暴力虐待"),
    ("不倫戀情", "novel_search/all/不倫戀情"),
    ("群體換伴", "novel_search/all/群體換伴"),
    ("人妻熟女", "novel_search/all/人妻熟女"),
    ("科學幻想", "novel_search/all/科學幻想"),
    ("其他故事", "novel_search/all/其他故事"),
    ("玄幻仙俠", "novel_search/all/玄幻仙俠"),
    ("動漫修改", "novel_search/all/動漫修改"),
    ("長篇連載", "novel_search/all/長篇連載"),
]

BLOCKED_LABELS = ["萝莉", "蘿莉", "幼女", "幼齿", "幼齒", "初中生", "國中生", "小学生", "小學生", "未成年", "loli", "lolita", "正太", "shota"]

_CACHE = {}
_TAG_CACHE = {}
_CODE_RE = re.compile(r"[A-Z]{2,6}[-_ ]?\d{2,5}")


def _blocked_label(label):
    low = (label or "").lower()
    for w in BLOCKED_LABELS:
        if w in low:
            return True
    return False


_SSL_CTX = None


def _ssl_ctx():
    global _SSL_CTX
    if _SSL_CTX is None:
        _SSL_CTX = ssl.create_default_context()
    return _SSL_CTX


def _proxy_for(parsed):
    host = (parsed.hostname or "").lower()
    no_proxy = os.environ.get("no_proxy") or os.environ.get("NO_PROXY") or ""
    for item in no_proxy.replace(",", " ").split():
        item = item.strip().lower()
        if item and (host == item or host.endswith("." + item) or item == "*"):
            return None
    if parsed.scheme == "https":
        raw = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or ""
    else:
        raw = os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY") or ""
    if not raw:
        return None
    p = urllib.parse.urlparse(raw if "://" in raw else "http://" + raw)
    if not p.hostname:
        return None
    return (p.hostname, p.port or 80)


def _http_get_once(url, timeout, headers=None, depth=0):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    req_headers = {"User-Agent": UA, "Host": parsed.netloc}
    if headers:
        req_headers.update(headers)
    proxy = _proxy_for(parsed)
    if proxy:
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(proxy[0], proxy[1], timeout=timeout, context=_ssl_ctx())
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPConnection(proxy[0], proxy[1], timeout=timeout)
            path = url
    elif parsed.scheme == "https":
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=_ssl_ctx())
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path, headers=req_headers)
        resp = conn.getresponse()
        status = resp.status
        data = resp.read()
        headers_out = dict((k.lower(), v) for k, v in resp.getheaders())
        if status in (301, 302, 303, 307, 308) and depth < 2:
            loc = headers_out.get("location") or ""
            if loc:
                return _http_get_once(urllib.parse.urljoin(url, loc), timeout, headers, depth + 1)
        if status != 200:
            raise ValueError("http %d" % status)
        if "gzip" in (headers_out.get("content-encoding") or "").lower():
            data = gzip.decompress(data)
        return data
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _fetch_text(url, headers=None, timeout=30, attempts=3):
    for attempt in range(attempts):
        try:
            raw = _http_get_once(url, timeout, headers)
            return raw.decode("utf-8", "ignore")
        except Exception:
            time.sleep(0.6 * (attempt + 1))
    return ""


def _http_json(url, timeout=35, attempts=4):
    for attempt in range(attempts):
        try:
            raw = _http_get_once(url, timeout, {"Accept": "application/json"})
            text = raw.decode("utf-8", "ignore")
            if text.lstrip().startswith("<"):
                return None
            return json.loads(text)
        except Exception:
            time.sleep(0.6 * (attempt + 1))
    return None


def _quote_url(url):
    out = []
    for ch in url:
        o = ord(ch)
        if o < 0x80 and ch != " ":
            out.append(ch)
        elif ch == " ":
            out.append("%20")
        else:
            for b in ch.encode("utf-8"):
                out.append("%%%02X" % b)
    return "".join(out)


def _mjv_headers():
    return {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": HOST + "/",
        "Cookie": COOKIE,
    }


def _mjv_fetch(url, attempts=3, timeout=35, retried=False):
    text = _fetch_text(_quote_url(url), _mjv_headers(), timeout, attempts)
    if not retried and text and len(text) < 3000 and ("同意(enter)" in text or "IamOverEighteenYearsOld" in text):
        _fetch_text(_quote_url(AGE_URL), _mjv_headers(), timeout, 1)
        return _mjv_fetch(url, 1, timeout, True)
    return text


_AES_SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16]
_AES_INV_SBOX = [0] * 256
for _i, _v in enumerate(_AES_SBOX):
    _AES_INV_SBOX[_v] = _i
_AES_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]


def _aes_xtime(a):
    return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1) & 0xff


def _aes_mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _aes_xtime(a)
        b >>= 1
    return r


def _aes_expand(key):
    w = [list(key[i * 4:i * 4 + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [_AES_SBOX[t[1]] ^ _AES_RCON[i // 4 - 1], _AES_SBOX[t[2]], _AES_SBOX[t[3]], _AES_SBOX[t[0]]]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _aes_dec_block(block, w):
    s = [[block[4 * c + r] for c in range(4)] for r in range(4)]

    def ark(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd * 4 + c][r]

    def ishift():
        for r in range(1, 4):
            s[r] = s[r][-r:] + s[r][:-r]

    def isub():
        for r in range(4):
            for c in range(4):
                s[r][c] = _AES_INV_SBOX[s[r][c]]

    def imix():
        for c in range(4):
            a = [s[r][c] for r in range(4)]
            s[0][c] = _aes_mul(a[0], 14) ^ _aes_mul(a[1], 11) ^ _aes_mul(a[2], 13) ^ _aes_mul(a[3], 9)
            s[1][c] = _aes_mul(a[0], 9) ^ _aes_mul(a[1], 14) ^ _aes_mul(a[2], 11) ^ _aes_mul(a[3], 13)
            s[2][c] = _aes_mul(a[0], 13) ^ _aes_mul(a[1], 9) ^ _aes_mul(a[2], 14) ^ _aes_mul(a[3], 11)
            s[3][c] = _aes_mul(a[0], 11) ^ _aes_mul(a[1], 13) ^ _aes_mul(a[2], 9) ^ _aes_mul(a[3], 14)

    ark(10)
    for rnd in range(9, 0, -1):
        ishift()
        isub()
        ark(rnd)
        imix()
    ishift()
    isub()
    ark(0)
    return bytes(s[r][c] for c in range(4) for r in range(4))


def _aes_cbc_decrypt(data, key, iv):
    if not data or len(data) % 16:
        return data
    w = _aes_expand(key[:16])
    prev = iv[:16]
    out = b""
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        dec = _aes_dec_block(blk, w)
        out += bytes(dec[j] ^ prev[j] for j in range(16))
        prev = blk
    pad = out[-1]
    if 1 <= pad <= 16:
        out = out[:-pad]
    return out


def _decrypt_id(enc, xor_key, base, aes_key, aes_iv):
    sep = chr(base + 97)
    parts = []
    start = 0
    while True:
        idx = enc.find(sep, start)
        part = enc[start:] if idx < 0 else enc[start:idx]
        if part:
            try:
                ch = int(part, base) ^ xor_key
            except Exception:
                return ""
            if ch < 0 or ch > 0x10FFFF:
                return ""
            parts.append(chr(ch))
        if idx < 0:
            break
        start = idx + 1
    try:
        data = base64.b64decode("".join(parts))
    except Exception:
        return ""
    try:
        return _aes_cbc_decrypt(data, aes_key.encode("utf-8"), aes_iv.encode("utf-8")).decode("utf-8", "ignore")
    except Exception:
        return ""


def _strip_tags(s):
    return re.sub(r"<[^>]+>", "", s or "")


def _first_group(text, regex, flags=0):
    m = re.search(regex, text or "", flags)
    if m:
        g = m.group(1)
        return g if g is not None else ""
    return ""


def _is_novel(s):
    return bool(s) and s.startswith("novel")


def _is_image(s):
    if not s:
        return False
    return s.startswith("18H") or s.startswith("doujin") or s.startswith("cg") or s.startswith("cwp")


def _card(vod_id, name, pic, remarks):
    return {"vod_id": vod_id, "vod_name": name, "vod_pic": pic, "vod_remarks": remarks}


def _parse_video_posts(text):
    items = []
    if not text:
        return items
    seen = set()
    chunks = text.split("<div class='post video_9s'>")
    for chunk in chunks[1:]:
        mm = re.search(r'href="([^"]*?/([^/]+)_content/(\d+)/([^/]+)\.html)"', chunk)
        if not mm:
            continue
        vod_id = mm.group(2) + "#" + mm.group(3) + "#" + mm.group(4)
        if vod_id in seen:
            continue
        seen.add(vod_id)
        pic = _first_group(chunk, r"<img[^>]*src='([^']+)'")
        title = _first_group(chunk, r"<h3[^>]*><a[^>]*>([^<]+)</a></h3>").strip()
        date = _first_group(chunk, r"<div class='meta'>([^<]*)</div>").strip()
        if not title:
            continue
        items.append(_card(vod_id, html.unescape(title), pic, date))
    return items


def _parse_text_posts(text):
    items = []
    if not text:
        return items
    for m in re.finditer(r"<div class='post'>\s*<div class='con'>\s*<h3[^>]*><a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a></h3>", text):
        mm = re.search(r"/([^/]+)_content/(\d+)/([^/]+)\.html", m.group(1))
        if not mm:
            continue
        items.append(_card(mm.group(1) + "#" + mm.group(2) + "#" + mm.group(3), html.unescape(m.group(2).strip()), "", ""))
    return items


def _parse_posts(text, tid):
    if _is_novel(tid):
        return _parse_text_posts(text)
    if text and "video_9s" in text:
        v = _parse_video_posts(text)
        if v:
            return v
    items = []
    if not text:
        return items
    p1 = re.compile(r"<div class='post'>\s*<a[^>]*href=\"([^\"]+)\"[^>]*><img[^>]*src='([^']+)'[^>]*>\s*</a>\s*<div class='con'>\s*<h3[^>]*><a[^>]*>([^<]+)</a></h3>(?:\s*<div class='meta'>([^<]*)</div>)?", re.S)
    found1 = False
    for m1 in p1.finditer(text):
        found1 = True
        href = m1.group(1)
        pic = m1.group(2)
        title = m1.group(3)
        date = m1.group(4) or ""
        if href.startswith(HOST):
            href = href[len(HOST):]
        if not href or not href.startswith("/"):
            continue
        mm = re.search(r"/([^/]+)_content/(\d+)/([^/]+)\.html", href)
        if not mm:
            continue
        items.append(_card(mm.group(1) + "#" + mm.group(2) + "#" + mm.group(3), html.unescape(title.strip()), pic, date.strip()))
    if found1:
        return items
    p2 = re.compile(r"<a[^>]+href=\"([^\"]*zh/[^\"]*_content/[^\"]*)\"[^>]*>.*?<img[^>]+src=\"([^\"]+)\"[^>]*>.*?<(?:h3|h2|h4|div\s+class=\"title\")[^>]*>(.*?)</", re.S | re.I)
    for m2 in p2.finditer(text):
        href = m2.group(1)
        pic = m2.group(2)
        title = _strip_tags(m2.group(3)).strip()
        if href.startswith(HOST):
            href = href[len(HOST):]
        if not href or not href.startswith("/"):
            continue
        mm = re.search(r"/([^/]+)_content/(\d+)/([^/]+)\.html", href)
        if not mm:
            continue
        items.append(_card(mm.group(1) + "#" + mm.group(2) + "#" + mm.group(3), html.unescape(title), pic, ""))
    return items


def _label_of_path(path):
    last = len(path)
    count = 0
    cut = 0
    i = len(path) - 1
    while i >= 0 and count < 2:
        if path[i] == "/":
            count += 1
            if count == 2:
                cut = i
        i -= 1
    head = path[:cut] if count == 2 else path
    slash = head.rfind("/")
    return head if slash < 0 else head[slash + 1:]


def _quote_sub(sub):
    decoded = urllib.parse.unquote(sub)
    return urllib.parse.quote(decoded, safe="/()")


def _get_category_tags(tid):
    if tid in _TAG_CACHE:
        return _TAG_CACHE[tid]
    tags = []
    if _is_novel(tid) or _is_image(tid):
        _TAG_CACHE[tid] = tags
        return tags
    base_tid = tid
    if base_tid.endswith("_random/all"):
        base_tid = base_tid[:-11]
    elif base_tid.endswith("_random"):
        base_tid = base_tid[:-7]
    text = ""
    for u in (HOST + "/zh/" + base_tid + "_random/all/index.html",
              HOST + "/zh/" + base_tid + "_list/all/index.html",
              HOST + "/zh/" + base_tid + "/index.html"):
        try:
            text = _mjv_fetch(u, attempts=1, timeout=30)
        except Exception:
            text = ""
        if text:
            break
    if text:
        p = re.compile(r"href=['\"](/zh/((?:" + re.escape(base_tid) + r")_(?:search|tag)/all/[^'\"/]+/))['\"]", re.I)
        seen = set()
        for m in p.finditer(text):
            path = m.group(1)
            try:
                label = urllib.parse.unquote(_label_of_path(path))
            except Exception:
                label = _label_of_path(path)
            if not label or label in seen or _blocked_label(label) or _blocked_label(path):
                continue
            seen.add(label)
            tags.append([label, path])
    _TAG_CACHE[tid] = tags
    return tags


def _filter_entry(key, name, opts):
    return {"key": key, "name": name, "value": [{"n": o[0], "v": o[1]} for o in opts]}


def _build_filters():
    filters = {}
    opts = [["全部", ""]]
    seen = set()
    for label, path in _get_category_tags("chinese_random/all"):
        if label not in seen:
            seen.add(label)
            opts.append([label, path])
    for label, path in CHINESE_CATS:
        if label not in seen:
            seen.add(label)
            opts.append([label, path])
    filters["chinese_random/all"] = [_filter_entry("sub", "分类", opts)]
    for tid in ("censored_random/all", "uncensored_random/all", "amateurjav_random/all", "reducing-mosaic_random/all"):
        dynamic = _get_category_tags(tid)
        if tid == "uncensored_random/all":
            o = [["全部", ""]] + dynamic + [["——厂商筛选——", ""]] + [list(x) for x in UNCENSORED_MAKERS]
            filters[tid] = [_filter_entry("sub", "筛选", o)]
        elif dynamic:
            filters[tid] = [_filter_entry("sub", "标签", [["全部", ""]] + dynamic)]
    filters["cg_random/all"] = [_filter_entry("sub", "系列", [list(x) for x in CG_OPTS])]
    filters["cwp_random/all"] = [_filter_entry("sub", "系列", [list(x) for x in CWP_OPTS])]
    filters["novel_random/all"] = [_filter_entry("sub", "主题", [list(x) for x in NOVEL_OPTS])]
    return filters


def _load_classes(text):
    classes = []
    if not text:
        return classes
    seen = set()
    p = re.compile(r"href=['\"](https://mjv011\.com/zh/([^'\"/_]+)_random/all/index\.html)['\"][^>]*>([^<]+)</a>")
    for m in p.finditer(text):
        key = m.group(2)
        name = re.sub(r"\s*\(\d+\)\s*$", "", m.group(3).strip())
        if "random" in name or "隨機" in name or "随机" in name or "近作" in name:
            continue
        if _blocked_label(name):
            continue
        tid = key + "_random/all"
        if tid in seen:
            continue
        seen.add(tid)
        classes.append({"type_id": tid, "type_name": name})
    return classes


def _category_mjv(tid, pg, extend):
    if tid == "home":
        text = _mjv_fetch(AGE_URL)
        items = _parse_posts(text, "chinese_random/all")
        per_page = 20
        total = len(items)
        start = (pg - 1) * per_page
        page_items = items[start:start + per_page]
        pagecount = (total + per_page - 1) // per_page if total else 1
        return {"list": page_items, "page": pg, "pagecount": pagecount, "limit": len(page_items), "total": total}
    if tid == "content_news/all":
        today = date.today().isoformat()
        text = _mjv_fetch(HOST + "/zh/content_news/all/" + today + ".html")
        items = _parse_posts(text, tid)
        return {"list": items, "page": 1, "pagecount": 1, "limit": len(items), "total": len(items)}
    candidates = []
    sub = (extend or {}).get("sub") if isinstance(extend, dict) else None
    if sub:
        candidates.append(HOST + "/zh/" + _quote_sub(sub) + "/" + str(pg) + ".html")
    if tid.startswith("search_"):
        kw = tid[7:]
        candidates.append(HOST + "/zh/chinese_search/all/" + kw + "/" + str(pg) + ".html")
    else:
        base_tid = tid
        if base_tid.endswith("_random/all"):
            base_tid = base_tid[:-11]
        elif base_tid.endswith("_random"):
            base_tid = base_tid[:-7]
        elif base_tid.endswith("_list/all"):
            base_tid = base_tid[:-10]
        if pg == 1:
            candidates.append(HOST + "/zh/" + base_tid + "_list/all/index.html")
            candidates.append(HOST + "/zh/" + base_tid + "_random/all/index.html")
        candidates.append(HOST + "/zh/" + base_tid + "_list/all/" + str(pg) + ".html")
        candidates.append(HOST + "/zh/" + base_tid + "_list/index_" + str(pg) + ".html")
        candidates.append(HOST + "/zh/" + base_tid + "/" + str(pg) + ".html")
        candidates.append(HOST + "/zh/" + base_tid + "/page/" + str(pg) + ".html")
        candidates.append(HOST + "/zh/" + base_tid + "_random/all/" + str(pg) + ".html")
        if pg > 1:
            candidates.append(HOST + "/zh/" + base_tid + "_list/index_" + str(pg) + ".html")
    items = []
    for url in candidates:
        text = _mjv_fetch(url)
        if not text:
            continue
        parse_tid = tid
        if sub:
            if _is_novel(sub):
                parse_tid = "novel_random/all"
            elif _is_image(sub):
                parse_tid = (sub.split("_")[0] + "_random/all") if "_" in sub else "cg_random/all"
        items = _parse_posts(text, parse_tid)
        if items:
            break
    return {"list": items, "page": pg, "pagecount": pg + 1, "limit": len(items), "total": pg * len(items) + 1}


def _detail_text(ctype, num, slug):
    url = HOST + "/zh/" + ctype + "_content/" + num + "/" + slug + ".html"
    return _mjv_fetch(url)


def _extract_pids(text):
    hadeedg = _first_group(text, r"hadeedg252=(\d+)")
    hcdeedg = _first_group(text, r"hcdeedg252=(\d+)")
    aes_key = _first_group(text, r"var argdeqweqweqwe = '([^']+)'")
    aes_iv = _first_group(text, r"var hdddedg252 = '([^']+)'")
    mvarr = _first_group(text, r"mvarr\['10_1'\]=(\[.*?\]);", re.S)
    if not hadeedg or not hcdeedg or not aes_key or not aes_iv or not mvarr:
        return []
    try:
        xor_key = int(hadeedg)
        base = int(hcdeedg)
    except Exception:
        return []
    pids = []
    for im in re.finditer(r"\['([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)'\]", mvarr):
        enc = im.group(2)
        prefix = im.group(4)
        if not enc or not prefix:
            continue
        pid = _decrypt_id(enc, xor_key, base, aes_key, aes_iv)
        if pid:
            pids.append(pid)
    return pids


def _video_detail(vid, ctype, num, slug):
    text = _detail_text(ctype, num, slug)
    if not text:
        return {"list": []}
    title = _strip_tags(_first_group(text, r"<h1[^>]*>(.*?)</h1>", re.S)).strip()
    if not title:
        title = _first_group(text, r"<title>([^<]+)</title>").strip()
    cover = _first_group(text, r'"thumbnailUrl"\s*:\s*"([^"]+)"')
    if not cover:
        cover = _first_group(text, r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
    if not cover:
        cover = _first_group(text, r"<div class='post'>.*?<img[^>]*src='([^']+)'", re.S)
    pids = _extract_pids(text)
    if not pids:
        return {"list": []}
    play_url = []
    for pid in pids:
        for label, res in (("480P", "480"), ("720P", "720"), ("1080P", "1080")):
            play_url.append("%s$%s|%s|%s|%s" % (label, num, slug, pid, res))
    vod = {
        "vod_id": vid,
        "vod_name": html.unescape(title),
        "vod_pic": cover,
        "vod_content": "",
        "vod_remarks": "",
        "vod_play_from": "mjv011",
        "vod_play_url": "#".join(play_url),
    }
    return {"list": [vod]}


def _clean_text(raw):
    s = _strip_tags(raw)
    s = s.replace("&nbsp;", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _novel_detail(vid, ctype, num, slug):
    text = _detail_text(ctype, num, slug)
    if not text:
        return {"list": []}
    title = _strip_tags(_first_group(text, r"<h1[^>]*>(.*?)</h1>", re.S)).strip()
    content = ""
    raw = _first_group(text, r"id=['\"]novel_content_txtsize['\"][^>]*>(.*?)</div>", re.S)
    if raw:
        content = _clean_text(raw)
    if not content:
        raw = _first_group(text, r"<span class='content_18h_wpcg'>([\s\S]*?)</span>\s*<div class='contents'")
        if raw:
            content = _clean_text(raw)
    if len(content) > 3000:
        content = content[:3000] + "..."
    nj = json.dumps({"title": title, "content": content}, ensure_ascii=False)
    vod = {
        "vod_id": vid,
        "vod_name": html.unescape(title),
        "vod_pic": "",
        "vod_content": "",
        "vod_remarks": "",
        "vod_play_from": "小说",
        "vod_play_url": "阅读$novel://" + nj,
        "vod_tag": "text",
        "vod_player": "书",
    }
    return {"list": [vod]}


def _image_detail(vid, ctype, num, slug):
    text = _detail_text(ctype, num, slug)
    if not text:
        return {"list": []}
    title = _strip_tags(_first_group(text, r"<h1[^>]*>(.*?)</h1>", re.S)).strip()
    cover = _first_group(text, r'"thumbnailUrl"\s*:\s*"([^"]+)"')
    big_imgs = []
    seen = set()
    pairs = re.findall(r"Large_cgurl\[(\d+)\]\s*=\s*\"([^\"]+)\"", text)
    pairs.sort(key=lambda p: int(p[0]))
    for _idx, img in pairs:
        if img in seen:
            continue
        seen.add(img)
        big_imgs.append(img)
    if not big_imgs:
        for m in re.finditer(r"src=['\"]([^'\"]*eemmhh02\.com/[^'\"]+\.(?:jpg|png|webp))['\"]", text, re.I):
            img = m.group(1)
            if img in seen:
                continue
            seen.add(img)
            big_imgs.append(img)
    if not big_imgs:
        return {"list": []}
    vod = {
        "vod_id": vid,
        "vod_name": html.unescape(title),
        "vod_pic": cover,
        "vod_content": "共 %d 张图片" % len(big_imgs),
        "vod_remarks": "%dP" % len(big_imgs),
        "vod_play_from": "图片",
        "vod_play_url": "查看$pics://" + "&&".join(big_imgs),
        "vod_tag": "image",
        "vod_player": "画",
    }
    return {"list": [vod]}


def _playphp(pid, res):
    url = HOST + "/js/player/play.php?numresolution=" + str(res) + "&lo=on&id=" + pid
    text = _mjv_fetch(url)
    m3u8 = ""
    if text:
        arr = _first_group(text, r"videoSources\s*=\s*(\[.*?\]);", re.S)
        if arr:
            sources = []
            for sm in re.finditer(r"src:\s*'([^']+)'[^}]*?size:\s*(\d+)", arr, re.S):
                sources.append((sm.group(1), sm.group(2)))
            try:
                target = int(res)
            except Exception:
                target = 0
            for src, size in sources:
                try:
                    sz = int(size)
                except Exception:
                    sz = 0
                if sz == target:
                    m3u8 = src
                    break
            if not m3u8 and sources:
                m3u8 = sources[0][0]
        if not m3u8:
            m3u8 = _first_group(text, r"https?://[^\s\"<>']+?\.m3u8")
    return m3u8


def _mjv_search_play(code):
    url = HOST + "/zh/chinese_search/all/" + urllib.parse.quote(code) + "/1.html"
    text = _mjv_fetch(url, attempts=2, timeout=35)
    items = _parse_posts(text, "chinese_random/all")
    for it in items:
        parts = (it.get("vod_id") or "").split("#", 2)
        if len(parts) != 3:
            continue
        ctype, num, slug = parts
        if _is_novel(ctype) or _is_image(ctype):
            continue
        pids = _extract_pids(_detail_text(ctype, num, slug))
        if pids:
            m3u8 = _playphp(pids[0], "720")
            if m3u8:
                return m3u8
    return ""


def _cached(key, loader):
    if key not in _CACHE:
        try:
            _CACHE[key] = loader()
        except Exception:
            _CACHE[key] = None
    return _CACHE[key]


def _roster():
    def load():
        d = _http_json(WEB + "/jp220/actors.json?v=" + JP_V, timeout=45)
        if isinstance(d, dict):
            return d.get("actors") or []
        return d or []
    return _cached("roster", load) or []


def _src_bucket(bucket):
    def load():
        d = _http_json(WEB + "/jp220/src/" + str(bucket) + ".json?v=" + JP_V, timeout=20)
        return d if isinstance(d, dict) else {}
    return _cached("src:%d" % bucket, load) or {}


def _code_bucket(bucket):
    def load():
        d = _http_json(WEB + "/jp220/c/" + str(bucket) + ".json?v=" + JP_V, timeout=20)
        return d if isinstance(d, dict) else {}
    return _cached("code:%d" % bucket, load) or {}


def _norm_text(s):
    return re.sub(r"[^A-Z0-9]", "", (s or "").upper())


def _code_key(s):
    n = _norm_text(s)
    m = re.match(r"^([A-Z]+)0*(\d+)$", n)
    return (m.group(1) + m.group(2)) if m else n


def _code_of(name):
    m = _CODE_RE.search((name or "").upper())
    if not m:
        return ""
    return re.sub(r"[\s_]+", "-", m.group(0))


def _bucket(key):
    h = 0x811C9DC5
    for ch in key:
        h ^= ord(ch)
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h % 256


def _src_lookup(code):
    k = _code_key(code)
    if not k:
        return ""
    v = _src_bucket(_bucket(k)).get(k)
    if isinstance(v, list) and len(v) > 1 and isinstance(v[1], list):
        for row in v[1]:
            if isinstance(row, list) and len(row) > 2 and str(row[2]).startswith("http"):
                return str(row[2])
    return ""


def _resolve_code(code):
    url = _src_lookup(code)
    if url:
        return url, False
    return _mjv_search_play(code), True


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg > 0 else 1


def _norm_ids(ids):
    if isinstance(ids, str):
        return [ids]
    if isinstance(ids, (list, tuple)):
        return [str(x) for x in ids]
    return [str(ids)]


def _play_header():
    return {"User-Agent": UA, "Referer": WEB + "/"}


def _mjv_play_header():
    return {"User-Agent": UA, "Referer": HOST + "/"}


class Spider(BaseSpider):
    def getName(self):
        return "潮流AV"

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        text = ""
        try:
            text = _mjv_fetch(AGE_URL, attempts=2, timeout=35)
        except Exception:
            text = ""
        classes = _load_classes(text)
        if not classes:
            classes = [{"type_id": base + "_random/all", "type_name": name} for base, name in MJV_CATS]
        out_classes = [{"type_id": "home", "type_name": "首页"}, {"type_id": "content_news/all", "type_name": "每日更新"}]
        for c in classes:
            if c["type_id"] in ("home", "content_news/all"):
                continue
            out_classes.append(c)
        out_classes.append({"type_id": "jp", "type_name": "女优库"})
        for key, name, _mp in TUKU:
            out_classes.append({"type_id": "tk_" + key, "type_name": name})
        items = _parse_posts(text, "chinese_random/all") if text else []
        try:
            filters = _build_filters()
        except Exception:
            filters = {}
        return {"class": out_classes, "list": items, "filters": filters}

    def homeVideoContent(self):
        text = ""
        try:
            text = _mjv_fetch(AGE_URL, attempts=2, timeout=35)
        except Exception:
            text = ""
        return {"list": _parse_posts(text, "chinese_random/all") if text else []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or "")
        if tid == "jp":
            return self._cat_jp(pg)
        if tid.startswith("tk_"):
            return self._cat_tuku(tid[3:], pg)
        return _category_mjv(tid, pg, extend or {})

    def _cat_jp(self, pg):
        roster = _roster()
        total = len(roster)
        out = []
        for a in roster[(pg - 1) * PAGE:pg * PAGE]:
            aid = str(a.get("id") or "")
            pic = a.get("a") or (WEB + "/jp/av/" + aid + ".jpg")
            out.append({
                "vod_id": "jp_" + aid,
                "vod_name": a.get("n") or "",
                "vod_pic": pic,
                "vod_remarks": "作品 %s 部" % (a.get("t") or 0),
            })
        pagecount = (total + PAGE - 1) // PAGE if total else 1
        return {"list": out, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def _cat_tuku(self, key, pg):
        max_page = 5
        for k, _n, mp in TUKU:
            if k == key:
                max_page = mp
                break
        d = _http_json(WEB + "/data220/%s_%d.json?v=4" % (key, pg), timeout=35)
        items = (d or {}).get("items") or []
        out = []
        for v in items:
            imgs = v.get("imgs") or []
            out.append({
                "vod_id": "tk_%s_%d_%s" % (key, pg, v.get("id")),
                "vod_name": (v.get("title") or "").strip(),
                "vod_pic": WEB + "/" + str(v.get("thumb") or "").lstrip("/"),
                "vod_remarks": "%s %s 共 %d 张" % ((v.get("actress") or "").strip(), (v.get("date") or "").strip(), len(imgs)),
            })
        total = 0
        try:
            total = int((d or {}).get("total") or 0)
        except Exception:
            pass
        return {"list": out, "page": pg, "pagecount": max_page, "limit": len(out), "total": total}

    def detailContent(self, ids):
        ids = _norm_ids(ids)
        vid = (ids[0] if ids else "").strip()
        if vid.startswith("jp_"):
            return self._detail_jp(vid[3:])
        if vid.startswith("tk_"):
            return self._detail_tuku(vid)
        if vid.startswith("code_"):
            code = vid[5:]
            return {"list": [{
                "vod_id": vid,
                "vod_name": code,
                "vod_pic": "",
                "vod_content": code,
                "vod_play_from": "番号解析",
                "vod_play_url": "正片$jpcode:" + code,
            }]}
        parts = vid.split("#", 2)
        if len(parts) == 3:
            ctype, num, slug = parts
            if _is_novel(ctype):
                return _novel_detail(vid, ctype, num, slug)
            if _is_image(ctype):
                return _image_detail(vid, ctype, num, slug)
            return _video_detail(vid, ctype, num, slug)
        return {"list": []}

    def _detail_jp(self, aid):
        roster = _roster()
        actor = None
        for a in roster:
            if str(a.get("id")) == aid:
                actor = a
                break
        name = (actor or {}).get("n") or aid
        pic = (actor or {}).get("a") or (WEB + "/jp/av/" + aid + ".jpg")
        films = _http_json(WEB + "/jp220/f/" + urllib.parse.quote(aid) + ".json?v=" + JP_V, timeout=45)
        eps = []
        if isinstance(films, list):
            for f in films[:200]:
                if not isinstance(f, list) or len(f) < 2:
                    continue
                code = str(f[1] or "")
                date = str(f[2] or "") if len(f) > 2 else ""
                if code:
                    eps.append("%s %s$jpcode:%s" % (code, date, code))
        total = (actor or {}).get("t") or len(eps)
        return {"list": [{
            "vod_id": "jp_" + aid,
            "vod_name": name,
            "vod_pic": pic,
            "vod_actor": name,
            "vod_remarks": "作品 %s 部" % total,
            "vod_content": "%s，作品 %s 部" % (name, total),
            "vod_play_from": "女优作品",
            "vod_play_url": "#".join(eps),
        }]}

    def _detail_tuku(self, vid):
        m = re.match(r"^tk_([A-Za-z0-9]+)_(\d+)_(.+)$", vid)
        if not m:
            return {"list": []}
        key = m.group(1)
        pg = m.group(2)
        art_id = m.group(3)
        d = _http_json(WEB + "/data220/%s_%s.json?v=4" % (key, pg), timeout=35)
        for v in ((d or {}).get("items") or []):
            if str(v.get("id")) == art_id:
                imgs = [WEB + "/" + str(x).lstrip("/") for x in (v.get("imgs") or [])]
                return {"list": [{
                    "vod_id": vid,
                    "vod_name": (v.get("title") or "").strip(),
                    "vod_pic": WEB + "/" + str(v.get("thumb") or "").lstrip("/"),
                    "vod_actor": (v.get("actress") or "").strip(),
                    "vod_remarks": (v.get("date") or "").strip(),
                    "vod_content": (v.get("title") or "").strip(),
                    "vod_tag": "image",
                    "vod_play_from": "图片",
                    "vod_play_url": "查看$pics://" + "&&".join(imgs),
                }]}
        return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or "").strip()
        if not key:
            return {"list": []}
        res = _category_mjv("search_" + key, pg, {})
        items = res.get("list") or []
        seen = set()
        for it in items:
            seen.add(str(it.get("vod_id")))
        if pg == 1:
            k = _code_key(key)
            if len(k) >= 3 and any(c.isdigit() for c in k):
                hits = self._code_hits(k)
                for code, mid, date in hits[:20]:
                    vid = "code_" + code
                    if vid in seen:
                        continue
                    seen.add(vid)
                    pic = ""
                    if mid:
                        pic = "https://c0.jdbstatic.com/covers/" + str(mid)[:2].lower() + "/" + str(mid) + ".jpg"
                    items.append({
                        "vod_id": vid,
                        "vod_name": code,
                        "vod_pic": pic,
                        "vod_remarks": "番号命中 %s" % date,
                    })
        return {"list": items}

    def _code_hits(self, k):
        out = []
        seen = set()
        exact = _code_bucket(_bucket(k)).get(k) or []
        for r in exact:
            if isinstance(r, list) and len(r) >= 4:
                code = str(r[3] or k)
                if code not in seen:
                    seen.add(code)
                    out.append((code, str(r[0] or ""), str(r[2] or "")))
        if not out:
            group = _code_bucket(_bucket(k + "~")).get(k + "~") or []
            for r in group:
                if isinstance(r, list) and len(r) >= 4:
                    code = str(r[0] or "")
                    if code and code not in seen:
                        seen.add(code)
                        out.append((code, str(r[1] or ""), str(r[3] or "")))
        return out

    def playerContent(self, flag, id, vipFlags=None):
        ids = _norm_ids(id)
        raw = (ids[0] if ids else "").strip()
        if raw.startswith("jpcode:"):
            url, via_mjv = _resolve_code(raw[len("jpcode:"):])
            header = _mjv_play_header() if via_mjv else _play_header()
            return {"parse": 0, "playUrl": url, "url": url, "header": header}
        if raw.startswith("pics://") or raw.startswith("novel://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": {}}
        parts = raw.split("|")
        if len(parts) == 4:
            m3u8 = _playphp(parts[2], parts[3])
            return {"parse": 0, "playUrl": m3u8, "url": m3u8, "header": _mjv_play_header()}
        return {"parse": 0, "playUrl": raw, "url": raw, "header": _play_header()}

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = urllib.parse.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            parsed = urllib.parse.urlparse(target)
            headers = {"User-Agent": UA, "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc)}
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                        return [resp.status, ctype, resp.read(), {}]
                except urllib.error.HTTPError as e:
                    try:
                        body = e.read()
                    except Exception:
                        body = b""
                    return [e.code, e.headers.get("Content-Type") or "text/plain", body, {}]
                except Exception as e:
                    last_err = e
                    time.sleep(0.5)
            raise last_err
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower()
        return any(k in url for k in (".m3u8", ".mp4", ".m4s", ".ts"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
