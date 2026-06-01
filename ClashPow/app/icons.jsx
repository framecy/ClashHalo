// icons.jsx — minimal stroke icons (SF-symbol-ish). Functional UI glyphs only.
function Icon({ name, size = 16, stroke = 1.6, style = {}, fill = 'none' }) {
  const p = {
    width: size, height: size, viewBox: '0 0 24 24', fill,
    stroke: 'currentColor', strokeWidth: stroke,
    strokeLinecap: 'round', strokeLinejoin: 'round', style,
  };
  switch (name) {
    case 'gauge': return (<svg {...p}><path d="M12 13l4-3"/><circle cx="12" cy="13" r="8"/><path d="M5 19a9 9 0 0114 0"/></svg>);
    case 'rocket': return (<svg {...p}><path d="M5 15c-1 1-1.5 4-1.5 4s3-.5 4-1.5"/><path d="M9 14l-3-1a8 8 0 0111-9 8 8 0 01-7 11l-1-3"/><circle cx="14.5" cy="9.5" r="1.3"/></svg>);
    case 'link': return (<svg {...p}><path d="M9 12h6"/><path d="M10 8H8a4 4 0 000 8h2"/><path d="M14 8h2a4 4 0 010 8h-2"/></svg>);
    case 'share': return (<svg {...p}><circle cx="6" cy="12" r="2.4"/><circle cx="17" cy="6" r="2.4"/><circle cx="17" cy="18" r="2.4"/><path d="M8.2 11l6.6-3.6M8.2 13l6.6 3.6"/></svg>);
    case 'dns': return (<svg {...p}><rect x="4" y="4" width="16" height="6" rx="1.5"/><rect x="4" y="14" width="16" height="6" rx="1.5"/><path d="M8 7h.01M8 17h.01"/></svg>);
    case 'logs': return (<svg {...p}><path d="M5 5h14M5 9h14M5 13h9M5 17h11"/></svg>);
    case 'cloud': return (<svg {...p}><path d="M7 18a4 4 0 01-.5-8 6 6 0 0111.5 1.5A3.5 3.5 0 0117 18z"/><path d="M12 11v6m0 0l-2-2m2 2l2-2" /></svg>);
    case 'sliders': return (<svg {...p}><path d="M4 8h10M18 8h2M4 16h2M10 16h10"/><circle cx="16" cy="8" r="2"/><circle cx="8" cy="16" r="2"/></svg>);
    case 'recycle': return (<svg {...p}><path d="M7 7l-2 3 3.5.5"/><path d="M5 10a7 7 0 0111-3"/><path d="M17 17l2-3-3.5-.5"/><path d="M19 14a7 7 0 01-11 3"/></svg>);
    case 'shield': return (<svg {...p}><path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z"/></svg>);
    case 'balance': return (<svg {...p}><path d="M12 4v16M6 8h12"/><path d="M6 8l-2.5 5h5zM18 8l-2.5 5h5z"/></svg>);
    case 'play': return (<svg {...p}><path d="M8 6l10 6-10 6z" fill="currentColor" stroke="none"/></svg>);
    case 'spark': return (<svg {...p}><path d="M12 4l1.6 4.4L18 10l-4.4 1.6L12 16l-1.6-4.4L6 10l4.4-1.6z"/></svg>);
    case 'window': return (<svg {...p}><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M4 9h16"/></svg>);
    case 'apple': return (<svg {...p}><path d="M15.5 12.5c0-2 1.5-2.7 1.6-2.8-0.9-1.3-2.3-1.4-2.8-1.5-1.2-.1-2.3.7-2.9.7-.6 0-1.5-.7-2.5-.7-1.3 0-2.5.8-3.1 2-1.3 2.3-.3 5.7 1 7.5.6.9 1.3 1.9 2.3 1.8.9 0 1.3-.6 2.4-.6s1.4.6 2.4.6 1.6-.9 2.2-1.8c.7-1 .9-2 .9-2-.1 0-1.9-.7-2-2.9z"/><path d="M13.5 6.2c.5-.6.8-1.5.7-2.2-.7 0-1.6.5-2.1 1-.5.5-.9 1.4-.8 2.2.8.1 1.6-.4 2.2-1z" fill="currentColor" stroke="none"/></svg>);
    case 'compass': return (<svg {...p}><circle cx="12" cy="12" r="8"/><path d="M15 9l-1.5 4.5L9 15l1.5-4.5z" fill="currentColor" stroke="none"/></svg>);
    case 'search': return (<svg {...p}><circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/></svg>);
    case 'bolt': return (<svg {...p}><path d="M13 3L5 13h6l-1 8 8-10h-6z"/></svg>);
    case 'pause': return (<svg {...p}><rect x="7" y="6" width="3.5" height="12" rx="1" fill="currentColor" stroke="none"/><rect x="13.5" y="6" width="3.5" height="12" rx="1" fill="currentColor" stroke="none"/></svg>);
    case 'playfill': return (<svg {...p}><path d="M8 6l10 6-10 6z" fill="currentColor" stroke="none"/></svg>);
    case 'wrench': return (<svg {...p}><path d="M15 7a3.5 3.5 0 00-4.6 4.3L4 17.7 6.3 20l6.4-6.4A3.5 3.5 0 0017 9l-2 2-2-2z"/></svg>);
    case 'power': return (<svg {...p}><path d="M12 4v8"/><path d="M7.5 7a7 7 0 109 0"/></svg>);
    case 'check': return (<svg {...p}><path d="M5 12l5 5L19 7"/></svg>);
    case 'x': return (<svg {...p}><path d="M6 6l12 12M18 6L6 18"/></svg>);
    case 'chevR': return (<svg {...p}><path d="M9 6l6 6-6 6"/></svg>);
    case 'chevD': return (<svg {...p}><path d="M6 9l6 6 6-6"/></svg>);
    case 'grip': return (<svg {...p}><circle cx="9" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="18" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="18" r="1.3" fill="currentColor" stroke="none"/></svg>);
    case 'refresh': return (<svg {...p}><path d="M19 12a7 7 0 11-2-4.9M19 4v3.5h-3.5"/></svg>);
    case 'wifi': return (<svg {...p}><path d="M4 8a13 13 0 0116 0M7 11.5a8 8 0 0110 0M9.5 15a4 4 0 015 0"/><circle cx="12" cy="18" r="1" fill="currentColor" stroke="none"/></svg>);
    case 'battery': return (<svg {...p}><rect x="3" y="8" width="16" height="8" rx="2"/><path d="M21 11v2"/><rect x="5" y="10" width="10" height="4" rx="1" fill="currentColor" stroke="none"/></svg>);
    case 'globe': return (<svg {...p}><circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c2.5 2 2.5 14 0 16M12 4c-2.5 2-2.5 14 0 16"/></svg>);
    case 'plus': return (<svg {...p}><path d="M12 5v14M5 12h14"/></svg>);
    case 'lock': return (<svg {...p}><rect x="5" y="10" width="14" height="9" rx="2"/><path d="M8 10V7a4 4 0 018 0v3"/></svg>);
    case 'code': return (<svg {...p}><path d="M9 8l-4 4 4 4M15 8l4 4-4 4"/></svg>);
    case 'form': return (<svg {...p}><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 9h8M8 13h8M8 17h4"/></svg>);
    case 'dot': return (<svg {...p}><circle cx="12" cy="12" r="5" fill="currentColor" stroke="none"/></svg>);
    case 'gear': return (<svg {...p}><circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1"/></svg>);
    case 'updown': return (<svg {...p}><path d="M8 9l-3 3 3 3M5 12h6M16 9l3 3-3 3M19 12h-6"/></svg>);
    case 'clock': return (<svg {...p}><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>);
    default: return (<svg {...p}><circle cx="12" cy="12" r="7"/></svg>);
  }
}
window.Icon = Icon;
