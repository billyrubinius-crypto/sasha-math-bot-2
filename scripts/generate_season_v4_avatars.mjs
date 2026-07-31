import { mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const outputDir = fileURLToPath(new URL("../assets/season-avatars/", import.meta.url));

const specs = [
  ["ca26_01_avatar_field_notebook.svg", "Режим энергосбережения", "Спокойная капибара на летнем фоне.", "#FCD34D", "#2DD4BF", `
    <ellipse cx="256" cy="300" rx="156" ry="136" fill="#A86E45" stroke="#5B3828" stroke-width="18"/>
    <circle cx="150" cy="198" r="45" fill="#9A613D" stroke="#5B3828" stroke-width="18"/><circle cx="362" cy="198" r="45" fill="#9A613D" stroke="#5B3828" stroke-width="18"/>
    <ellipse cx="256" cy="328" rx="102" ry="70" fill="#C88C5F"/>
    <circle cx="199" cy="269" r="25" fill="#172033"/><circle cx="313" cy="269" r="25" fill="#172033"/>
    <circle cx="191" cy="260" r="8" fill="#fff"/><circle cx="305" cy="260" r="8" fill="#fff"/>
    <ellipse cx="256" cy="316" rx="31" ry="23" fill="#33221E"/><path d="M256 339q-28 28-57 3M256 339q28 28 57 3" fill="none" stroke="#5B3828" stroke-width="12" stroke-linecap="round"/>
    <path d="M380 112h70v40h-70zM380 152h40v28h-40z" fill="#F8FAFC" stroke="#17303A" stroke-width="10" stroke-linejoin="round"/>
  `],
  ["ca26_02_avatar_paper_planner.svg", "Нулевой заряд", "Хомяк с разряженной батарейкой.", "#FB923C", "#818CF8", `
    <circle cx="150" cy="210" r="64" fill="#F6C77B" stroke="#74452D" stroke-width="18"/><circle cx="362" cy="210" r="64" fill="#F6C77B" stroke="#74452D" stroke-width="18"/>
    <circle cx="256" cy="290" r="157" fill="#F2B863" stroke="#74452D" stroke-width="18"/>
    <ellipse cx="256" cy="330" rx="91" ry="82" fill="#FFF3D3"/>
    <circle cx="195" cy="267" r="27" fill="#1F2937"/><circle cx="317" cy="267" r="27" fill="#1F2937"/>
    <circle cx="187" cy="257" r="9" fill="#fff"/><circle cx="309" cy="257" r="9" fill="#fff"/>
    <circle cx="157" cy="326" r="27" fill="#FB7185" opacity=".75"/><circle cx="355" cy="326" r="27" fill="#FB7185" opacity=".75"/>
    <path d="M239 326q17-18 34 0q-17 19-34 0" fill="#A8553E"/>
    <rect x="351" y="85" width="106" height="61" rx="15" fill="#F8FAFC" stroke="#1F2937" stroke-width="12"/><path d="M457 104h15v23h-15z" fill="#1F2937"/><rect x="367" y="101" width="16" height="29" rx="7" fill="#EF4444"/>
  `],
  ["ca26_03_avatar_route_notebook.svg", "Неверный корпус", "Фиолетовый пришелец, который снова вошёл не туда.", "#A78BFA", "#22D3EE", `
    <path d="M256 108c112 0 164 91 148 205-12 90-67 132-148 132S120 403 108 313C92 199 144 108 256 108z" fill="#7856D8" stroke="#312E81" stroke-width="18"/>
    <path d="M256 108V63" stroke="#312E81" stroke-width="18" stroke-linecap="round"/><circle cx="256" cy="51" r="25" fill="#F472B6" stroke="#312E81" stroke-width="12"/>
    <ellipse cx="190" cy="262" rx="48" ry="66" fill="#15132A"/><ellipse cx="322" cy="262" rx="48" ry="66" fill="#15132A"/>
    <ellipse cx="177" cy="242" rx="14" ry="20" fill="#fff"/><ellipse cx="309" cy="242" rx="14" ry="20" fill="#fff"/>
    <path d="M216 361q40 24 80 0" fill="none" stroke="#E9D5FF" stroke-width="14" stroke-linecap="round"/>
    <path d="M82 120h89l-28-28m28 28-28 28" fill="none" stroke="#F8FAFC" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_04_avatar_autumn_planner.svg", "Вне расписания", "Кот с расписанием, которое уже не актуально.", "#FDBA74", "#64748B", `
    <path d="M119 244 142 105l108 76 120-76 23 139z" fill="#475569" stroke="#172033" stroke-width="18" stroke-linejoin="round"/>
    <rect x="108" y="182" width="296" height="258" rx="122" fill="#64748B" stroke="#172033" stroke-width="18"/>
    <circle cx="195" cy="282" r="27" fill="#0F172A"/><circle cx="317" cy="282" r="27" fill="#0F172A"/>
    <circle cx="187" cy="273" r="8" fill="#fff"/><circle cx="309" cy="273" r="8" fill="#fff"/>
    <path d="m238 331 18 17 18-17" fill="#FB7185" stroke="#172033" stroke-width="9" stroke-linejoin="round"/><path d="M256 348v25m0 0q-28 23-53 0m53 0q28 23 53 0" fill="none" stroke="#172033" stroke-width="10" stroke-linecap="round"/>
    <g stroke="#172033" stroke-width="8"><path d="M170 340 72 320M170 366 68 374M342 340l98-20M342 366l102 8"/></g>
    <rect x="319" y="88" width="121" height="92" rx="14" fill="#FFF7ED" stroke="#9A3412" stroke-width="11"/><path d="M340 118h78M340 145h54" stroke="#F97316" stroke-width="11" stroke-linecap="round"/>
  `],
  ["ca26_05_avatar_symmetry_leaf.svg", "Протокол симметрии", "Енот, который проверяет обе стороны.", "#F59E0B", "#94A3B8", `
    <circle cx="256" cy="286" r="161" fill="#94A3B8" stroke="#334155" stroke-width="18"/>
    <path d="M116 195 92 83l120 78M396 195l24-112-120 78" fill="#64748B" stroke="#334155" stroke-width="18" stroke-linejoin="round"/>
    <path d="M121 251q62-89 135-12 73-77 135 12-38 98-135 73-97 25-135-73z" fill="#334155"/>
    <ellipse cx="193" cy="266" rx="31" ry="37" fill="#F8FAFC"/><ellipse cx="319" cy="266" rx="31" ry="37" fill="#F8FAFC"/>
    <circle cx="198" cy="273" r="18" fill="#0F172A"/><circle cx="314" cy="273" r="18" fill="#0F172A"/>
    <path d="m229 331 27 22 27-22" fill="#172033"/><path d="M256 353q-23 31-52 10m52-10q23 31 52 10" fill="none" stroke="#172033" stroke-width="11" stroke-linecap="round"/>
    <path d="M256 95v337" stroke="#FDE68A" stroke-width="8" stroke-dasharray="16 18" opacity=".9"/>
  `],
  ["ca26_06_avatar_window_lamp.svg", "Дедлайн 23:59", "Лягушка не моргает до отправки.", "#38BDF8", "#22C55E", `
    <ellipse cx="164" cy="204" rx="66" ry="62" fill="#4ADE80" stroke="#166534" stroke-width="18"/><ellipse cx="348" cy="204" rx="66" ry="62" fill="#4ADE80" stroke="#166534" stroke-width="18"/>
    <ellipse cx="256" cy="310" rx="166" ry="137" fill="#22C55E" stroke="#166534" stroke-width="18"/>
    <circle cx="164" cy="204" r="28" fill="#F8FAFC"/><circle cx="348" cy="204" r="28" fill="#F8FAFC"/><circle cx="169" cy="209" r="15" fill="#172033"/><circle cx="343" cy="209" r="15" fill="#172033"/>
    <path d="M175 334q81 68 162 0" fill="none" stroke="#14532D" stroke-width="16" stroke-linecap="round"/>
    <rect x="313" y="82" width="146" height="70" rx="18" fill="#172033" stroke="#F8FAFC" stroke-width="10"/><text x="330" y="130" fill="#F87171" font-family="monospace" font-weight="800" font-size="38">23:59</text>
  `],
  ["ca26_07_avatar_connection_map.svg", "Сообщение доставлено", "Почтовый голубь с неуверенной галочкой.", "#60A5FA", "#94A3B8", `
    <ellipse cx="251" cy="303" rx="157" ry="132" fill="#94A3B8" stroke="#334155" stroke-width="18"/>
    <path d="M121 249q-42-91 52-128 79-32 128 47" fill="#A9BAC9" stroke="#334155" stroke-width="18"/>
    <circle cx="190" cy="212" r="25" fill="#F8FAFC"/><circle cx="194" cy="216" r="14" fill="#172033"/>
    <path d="m104 239-70 34 79 25" fill="#F59E0B" stroke="#92400E" stroke-width="13" stroke-linejoin="round"/>
    <path d="M296 237q125 14 134 142-104 54-188 2" fill="#64748B" stroke="#334155" stroke-width="18"/>
    <path d="M345 124h106v84H345z" fill="#F8FAFC" stroke="#334155" stroke-width="11"/><path d="m346 127 53 43 52-43" fill="none" stroke="#3B82F6" stroke-width="11"/>
    <path d="m367 234 22 23 47-55" fill="none" stroke="#22C55E" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_08_avatar_warm_window.svg", "Ночная смена", "Большой мотылёк у единственного света.", "#312E81", "#C084FC", `
    <path d="M246 252Q158 95 70 150q-28 150 154 193M266 252Q354 95 442 150q28 150-154 193" fill="#A855F7" stroke="#3B0764" stroke-width="18"/>
    <path d="M234 178q22-39 44 0l32 206q-54 62-108 0z" fill="#4C1D95" stroke="#2E1065" stroke-width="18"/>
    <path d="M238 182 190 95M274 182l48-87" stroke="#2E1065" stroke-width="14" stroke-linecap="round"/>
    <circle cx="233" cy="240" r="17" fill="#FDE68A"/><circle cx="279" cy="240" r="17" fill="#FDE68A"/>
    <path d="M114 210q74 20 98 95M398 210q-74 20-98 95" fill="none" stroke="#F0ABFC" stroke-width="16" stroke-linecap="round"/>
    <circle cx="420" cy="92" r="44" fill="#FDE68A" stroke="#FFF7ED" stroke-width="12"/>
  `],
  ["ca26_09_avatar_snow_crystal.svg", "Не тает", "Снежное существо сохраняет форму.", "#BAE6FD", "#F8FAFC", `
    <path d="M136 387q-47-39-14-91-25-62 40-93 22-79 102-48 69-45 111 25 73 14 62 88 50 63-9 111-29 72-102 46-63 44-112-10-50 12-78-28z" fill="#F8FAFC" stroke="#0EA5E9" stroke-width="18"/>
    <circle cx="203" cy="287" r="27" fill="#164E63"/><circle cx="317" cy="287" r="27" fill="#164E63"/>
    <circle cx="194" cy="278" r="9" fill="#fff"/><circle cx="308" cy="278" r="9" fill="#fff"/>
    <path d="M212 359q48 23 96 0" fill="none" stroke="#0E7490" stroke-width="13" stroke-linecap="round"/>
    <path d="M256 82v74M219 99l37 29 37-29" fill="none" stroke="#E0F2FE" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_10_avatar_december_clock.svg", "Ещё пять минут", "Будильник, который сам просит отсрочку.", "#FB7185", "#FBBF24", `
    <path d="M141 154 97 105M371 154l44-49" stroke="#7F1D1D" stroke-width="22" stroke-linecap="round"/>
    <path d="M103 109q36-50 77-9M409 109q-36-50-77-9" fill="#F87171" stroke="#7F1D1D" stroke-width="16" stroke-linecap="round"/>
    <circle cx="256" cy="285" r="159" fill="#F8FAFC" stroke="#7F1D1D" stroke-width="20"/>
    <circle cx="256" cy="285" r="126" fill="#FFF7ED" stroke="#FCA5A5" stroke-width="8"/>
    <circle cx="200" cy="270" r="23" fill="#1F2937"/><circle cx="312" cy="270" r="23" fill="#1F2937"/>
    <path d="M218 352q38-24 76 0" fill="none" stroke="#7F1D1D" stroke-width="13" stroke-linecap="round"/>
    <path d="M256 285V204M256 285l65 40" stroke="#EF4444" stroke-width="16" stroke-linecap="round"/>
    <path d="M174 431 143 465M338 431l31 34" stroke="#7F1D1D" stroke-width="20" stroke-linecap="round"/>
  `],
  ["ca26_11_avatar_holiday_workshop.svg", "Архив.zip", "Коробка-архив с новогодним бантом.", "#EF4444", "#22C55E", `
    <rect x="100" y="180" width="312" height="254" rx="42" fill="#DC2626" stroke="#7F1D1D" stroke-width="18"/>
    <path d="M256 181v253M101 263h310" stroke="#FCD34D" stroke-width="38"/>
    <path d="M256 180q-88-9-88-69 0-41 38-40 45 2 50 109zm0 0q88-9 88-69 0-41-38-40-45 2-50 109z" fill="#FCD34D" stroke="#92400E" stroke-width="14"/>
    <circle cx="193" cy="329" r="23" fill="#1F2937"/><circle cx="319" cy="329" r="23" fill="#1F2937"/>
    <path d="M218 381q38 22 76 0" fill="none" stroke="#7F1D1D" stroke-width="13" stroke-linecap="round"/>
    <path d="M347 103h95v52h-95z" fill="#F8FAFC" stroke="#14532D" stroke-width="10"/><text x="361" y="140" fill="#166534" font-family="monospace" font-weight="900" font-size="29">.ZIP</text>
  `],
  ["ca26_12_avatar_frost_window.svg", "Слабый сигнал", "Замёрзший пришелец ловит последнюю полоску.", "#67E8F9", "#2563EB", `
    <path d="M256 105c111 0 163 91 147 205-12 91-67 134-147 134s-135-43-147-134C93 196 145 105 256 105z" fill="#67E8F9" stroke="#155E75" stroke-width="18"/>
    <path d="M256 105V62" stroke="#155E75" stroke-width="18" stroke-linecap="round"/><circle cx="256" cy="50" r="24" fill="#F8FAFC" stroke="#155E75" stroke-width="11"/>
    <ellipse cx="193" cy="264" rx="45" ry="62" fill="#0C4A6E"/><ellipse cx="319" cy="264" rx="45" ry="62" fill="#0C4A6E"/>
    <ellipse cx="181" cy="243" rx="13" ry="18" fill="#fff"/><ellipse cx="307" cy="243" rx="13" ry="18" fill="#fff"/>
    <path d="M221 362q35-23 70 0" fill="none" stroke="#155E75" stroke-width="13" stroke-linecap="round"/>
    <path d="M366 154v-20M395 154v-45M424 154V82" stroke="#F8FAFC" stroke-width="16" stroke-linecap="round" opacity=".9"/>
    <path d="m95 188 48 24-37 34 50 24" fill="none" stroke="#E0F2FE" stroke-width="11" stroke-linecap="round"/>
  `],
  ["ca26_13_avatar_clean_page.svg", "Ошибка на полях", "Чернильная клякса смотрит с полей тетради.", "#E2E8F0", "#334155", `
    <path d="M113 385q-38-69 31-105-32-71 45-93 21-78 88-42 71-45 103 29 78 8 50 84 58 51-8 102 9 73-66 64-54 50-105 1-75 30-87-39z" fill="#172033" stroke="#020617" stroke-width="18"/>
    <circle cx="207" cy="282" r="32" fill="#F8FAFC"/><circle cx="317" cy="282" r="32" fill="#F8FAFC"/><circle cx="214" cy="290" r="17" fill="#0F172A"/><circle cx="310" cy="290" r="17" fill="#0F172A"/>
    <path d="M219 362q37 26 74 0" fill="none" stroke="#F8FAFC" stroke-width="13" stroke-linecap="round"/>
    <path d="M75 83h362v346" fill="none" stroke="#F8FAFC" stroke-width="17" opacity=".92"/><path d="M110 83v346" stroke="#F87171" stroke-width="10"/>
    <path d="m365 120 40 37-49 31" fill="none" stroke="#EF4444" stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_14_avatar_study_metronome.svg", "Восемь вкладок", "Осьминог пытается держать восемь дел сразу.", "#C084FC", "#60A5FA", `
    <circle cx="256" cy="246" r="133" fill="#A855F7" stroke="#581C87" stroke-width="18"/>
    <g fill="none" stroke="#7E22CE" stroke-width="34" stroke-linecap="round">
      <path d="M169 331q-89 76-50 120"/><path d="M205 357q-48 74-7 105"/><path d="M245 365q-18 75 22 98"/><path d="M285 363q27 76 67 83"/><path d="M323 343q70 62 101 20"/>
    </g>
    <circle cx="204" cy="238" r="29" fill="#F8FAFC"/><circle cx="308" cy="238" r="29" fill="#F8FAFC"/><circle cx="209" cy="245" r="16" fill="#172033"/><circle cx="303" cy="245" r="16" fill="#172033"/>
    <path d="M218 309q38 23 76 0" fill="none" stroke="#581C87" stroke-width="13" stroke-linecap="round"/>
    <path d="M91 97h120v58H91zM302 79h126v58H302zM329 158h102v48H329z" fill="#F8FAFC" stroke="#1D4ED8" stroke-width="10"/>
  `],
  ["ca26_15_avatar_support_point.svg", "Ещё попытка", "Жук снова карабкается вверх.", "#F97316", "#78350F", `
    <path d="M256 123v318" stroke="#451A03" stroke-width="18"/><ellipse cx="256" cy="294" rx="139" ry="151" fill="#F97316" stroke="#451A03" stroke-width="18"/>
    <path d="M256 147q-82-73-132 1M256 147q82-73 132 1" fill="none" stroke="#451A03" stroke-width="18" stroke-linecap="round"/>
    <path d="M125 270 66 224M123 332l-70 28M387 270l59-46M389 332l70 28" stroke="#451A03" stroke-width="18" stroke-linecap="round"/>
    <circle cx="201" cy="263" r="27" fill="#F8FAFC"/><circle cx="311" cy="263" r="27" fill="#F8FAFC"/><circle cx="206" cy="270" r="15" fill="#172033"/><circle cx="306" cy="270" r="15" fill="#172033"/>
    <path d="M215 355q41-27 82 0" fill="none" stroke="#7C2D12" stroke-width="13" stroke-linecap="round"/>
    <path d="m392 96 48 35-48 35" fill="none" stroke="#F8FAFC" stroke-width="15" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_16_avatar_spring_sprout.svg", "Новый рост", "Росток, у которого появилась идея.", "#86EFAC", "#22C55E", `
    <path d="M256 208q-12-117-120-112 8 100 120 112zM256 208q12-117 120-112-8 100-120 112z" fill="#4ADE80" stroke="#166534" stroke-width="18" stroke-linejoin="round"/>
    <path d="M256 188v91" stroke="#166534" stroke-width="19" stroke-linecap="round"/>
    <path d="M126 267h260l-34 174H160z" fill="#F97316" stroke="#7C2D12" stroke-width="18" stroke-linejoin="round"/>
    <path d="M109 267h294" stroke="#7C2D12" stroke-width="28" stroke-linecap="round"/>
    <circle cx="209" cy="337" r="27" fill="#1F2937"/><circle cx="303" cy="337" r="27" fill="#1F2937"/>
    <circle cx="200" cy="327" r="8" fill="#fff"/><circle cx="294" cy="327" r="8" fill="#fff"/>
    <path d="M218 390q38 25 76 0" fill="none" stroke="#7C2D12" stroke-width="13" stroke-linecap="round"/>
    <path d="M411 85v56M383 113h56" stroke="#FEF3C7" stroke-width="15" stroke-linecap="round"/>
  `],
  ["ca26_17_avatar_balance_disc.svg", "Держится", "Кот балансирует лучше расписания.", "#FDE68A", "#D6A56F", `
    <path d="M119 246 142 106l111 79 117-79 23 140z" fill="#D6A56F" stroke="#713F12" stroke-width="18" stroke-linejoin="round"/>
    <rect x="108" y="184" width="296" height="256" rx="122" fill="#E6B87E" stroke="#713F12" stroke-width="18"/>
    <circle cx="196" cy="283" r="27" fill="#1F2937"/><circle cx="316" cy="283" r="27" fill="#1F2937"/>
    <path d="m238 332 18 17 18-17" fill="#FB7185" stroke="#713F12" stroke-width="9"/><path d="M256 349q-23 31-51 10m51-10q23 31 51 10" fill="none" stroke="#713F12" stroke-width="10" stroke-linecap="round"/>
    <path d="M61 96h390M256 96v55M126 96l-45 93h90zm260 0-45 93h90z" fill="none" stroke="#F8FAFC" stroke-width="13" stroke-linejoin="round"/>
  `],
  ["ca26_18_avatar_launch_researcher.svg", "Турист с Альфы-7", "Пришелец в большом туристическом шлеме.", "#22D3EE", "#4F46E5", `
    <circle cx="256" cy="278" r="169" fill="#E0F2FE" stroke="#312E81" stroke-width="22"/>
    <circle cx="256" cy="281" r="128" fill="#22D3EE" stroke="#155E75" stroke-width="16"/>
    <ellipse cx="204" cy="272" rx="37" ry="50" fill="#082F49"/><ellipse cx="308" cy="272" rx="37" ry="50" fill="#082F49"/>
    <ellipse cx="194" cy="256" rx="11" ry="15" fill="#fff"/><ellipse cx="298" cy="256" rx="11" ry="15" fill="#fff"/>
    <path d="M220 354q36 22 72 0" fill="none" stroke="#155E75" stroke-width="13" stroke-linecap="round"/>
    <path d="M256 151V91" stroke="#312E81" stroke-width="16"/><circle cx="256" cy="75" r="25" fill="#F472B6" stroke="#312E81" stroke-width="11"/>
    <path d="M359 126q64 19 85 76" fill="none" stroke="#F8FAFC" stroke-width="14" stroke-linecap="round"/><circle cx="445" cy="209" r="13" fill="#FDE68A"/>
  `],
  ["ca26_19_avatar_reflection_umbrella.svg", "Метод тыка", "Утка выбирает ответ клювом.", "#FDE047", "#38BDF8", `
    <circle cx="253" cy="283" r="159" fill="#FDE047" stroke="#A16207" stroke-width="18"/>
    <path d="M120 190q18-93 112-96-18 76-112 96z" fill="#FEF08A" stroke="#A16207" stroke-width="16"/>
    <circle cx="196" cy="252" r="27" fill="#1F2937"/><circle cx="310" cy="252" r="27" fill="#1F2937"/>
    <circle cx="187" cy="243" r="8" fill="#fff"/><circle cx="301" cy="243" r="8" fill="#fff"/>
    <path d="m182 321 74-42 98 42-98 57z" fill="#FB923C" stroke="#9A3412" stroke-width="16" stroke-linejoin="round"/>
    <circle cx="409" cy="111" r="48" fill="#F8FAFC" stroke="#2563EB" stroke-width="12"/><text x="391" y="131" fill="#2563EB" font-family="sans-serif" font-weight="900" font-size="62">?</text>
  `],
  ["ca26_20_avatar_may_branch.svg", "Локальный дождь", "Облако с персональным прогнозом.", "#7DD3FC", "#2563EB", `
    <path d="M107 354q-55-60 11-111 5-88 96-86 49-81 126-26 89-8 91 83 77 39 34 116-22 76-109 56-62 60-123 5-77 24-126-37z" fill="#BAE6FD" stroke="#0369A1" stroke-width="18"/>
    <circle cx="203" cy="281" r="27" fill="#0C4A6E"/><circle cx="317" cy="281" r="27" fill="#0C4A6E"/>
    <circle cx="194" cy="272" r="8" fill="#fff"/><circle cx="308" cy="272" r="8" fill="#fff"/>
    <path d="M216 345q40-24 80 0" fill="none" stroke="#0369A1" stroke-width="13" stroke-linecap="round"/>
    <path d="M170 410l-24 48M256 410l-24 48M342 410l-24 48" stroke="#38BDF8" stroke-width="18" stroke-linecap="round"/>
    <path d="M380 91h62v62h-62z" fill="#F8FAFC" stroke="#0369A1" stroke-width="10"/><path d="m390 125 14 14 28-35" fill="none" stroke="#22C55E" stroke-width="9"/>
  `],
  ["ca26_21_avatar_school_bell.svg", "Вышел первым", "Школьный звонок уже на пути к двери.", "#FDBA74", "#F59E0B", `
    <path d="M134 351q54-38 54-169 0-81 68-81t68 81q0 131 54 169z" fill="#F59E0B" stroke="#78350F" stroke-width="19" stroke-linejoin="round"/>
    <path d="M113 351h286" stroke="#78350F" stroke-width="28" stroke-linecap="round"/><circle cx="256" cy="393" r="39" fill="#B45309" stroke="#78350F" stroke-width="14"/>
    <circle cx="216" cy="244" r="24" fill="#1F2937"/><circle cx="296" cy="244" r="24" fill="#1F2937"/>
    <path d="M218 301q38 27 76 0" fill="none" stroke="#78350F" stroke-width="13" stroke-linecap="round"/>
    <path d="M386 98h62M417 67v62" stroke="#F8FAFC" stroke-width="15" stroke-linecap="round"/>
    <path d="m88 413 51-1-24-24m24 24-24 24" fill="none" stroke="#F8FAFC" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  `],
  ["ca26_22_avatar_solution_timer.svg", "Загрузка 2%", "Мозг ждёт, пока ответ догрузится.", "#F9A8D4", "#8B5CF6", `
    <path d="M151 364q-70-37-31-106-37-68 31-105 21-79 92-46 68-48 112 17 79 3 66 78 63 47 11 105 28 75-50 92-47 66-112 23-70 41-119-18z" fill="#F9A8D4" stroke="#831843" stroke-width="18"/>
    <path d="M256 130v286M184 164q-25 44 18 75-51 28-16 82-31 31-8 72M328 164q25 44-18 75 51 28 16 82 31 31 8 72" fill="none" stroke="#BE185D" stroke-width="13" stroke-linecap="round"/>
    <circle cx="204" cy="279" r="26" fill="#1F2937"/><circle cx="308" cy="279" r="26" fill="#1F2937"/>
    <path d="M219 352q37-25 74 0" fill="none" stroke="#831843" stroke-width="13" stroke-linecap="round"/>
    <rect x="337" y="78" width="126" height="62" rx="18" fill="#F8FAFC" stroke="#6D28D9" stroke-width="10"/><rect x="351" y="94" width="15" height="30" rx="7" fill="#8B5CF6"/><text x="381" y="121" fill="#6D28D9" font-family="monospace" font-weight="900" font-size="28">2%</text>
  `],
  ["ca26_23_avatar_summer_backpack.svg", "Уже в отпуске", "Рюкзак мысленно уже едет к морю.", "#FB7185", "#22D3EE", `
    <rect x="119" y="132" width="274" height="309" rx="91" fill="#FB7185" stroke="#881337" stroke-width="19"/>
    <path d="M181 144q7-72 75-72t75 72" fill="none" stroke="#881337" stroke-width="24" stroke-linecap="round"/>
    <rect x="151" y="292" width="210" height="121" rx="45" fill="#F43F5E" stroke="#881337" stroke-width="15"/>
    <circle cx="203" cy="238" r="27" fill="#1F2937"/><circle cx="309" cy="238" r="27" fill="#1F2937"/>
    <circle cx="194" cy="229" r="8" fill="#fff"/><circle cx="300" cy="229" r="8" fill="#fff"/>
    <path d="M219 280q37 24 74 0" fill="none" stroke="#881337" stroke-width="13" stroke-linecap="round"/>
    <path d="M79 361q52-53 103 0t103 0 103 0 79 0" fill="none" stroke="#67E8F9" stroke-width="17" stroke-linecap="round"/>
    <circle cx="426" cy="104" r="45" fill="#FDE047" stroke="#F8FAFC" stroke-width="11"/>
  `],
];

function makeSvg(index, title, description, start, end, artwork) {
  const gradientId = `bg-${index + 1}`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img">
  <title>${title}</title>
  <desc>${description}</desc>
  <defs>
    <linearGradient id="${gradientId}" x1="0" y1="0" x2="1" y2="1">
      <stop stop-color="${start}"/>
      <stop offset="1" stop-color="${end}"/>
    </linearGradient>
  </defs>
  <rect width="512" height="512" rx="118" fill="url(#${gradientId})"/>
  <circle cx="80" cy="78" r="58" fill="#fff" opacity=".17"/>
  <circle cx="438" cy="420" r="94" fill="#fff" opacity=".1"/>
  ${artwork.trim()}
</svg>
`;
}

await mkdir(outputDir, { recursive: true });
await Promise.all(specs.map(([filename, title, description, start, end, artwork], index) =>
  writeFile(path.join(outputDir, filename), makeSvg(index, title, description, start, end, artwork), "utf8"),
));

console.log(`Generated ${specs.length} approved Season V4 avatar SVGs.`);
