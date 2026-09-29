/// <reference types="astro/client" />

declare module 'alpinejs' {
  const Alpine: any
  export default Alpine
}

interface Window {
  Alpine: any
  noteEditor: (date: string, initialContent: string) => any
  noteShell: () => any
  twttr?: {
    widgets: {
      createTweet: (
        id: string,
        element: HTMLElement,
        options?: {
          conversation?: 'none' | 'all'
          dnt?: boolean
          theme?: 'dark' | 'light'
        },
      ) => Promise<HTMLElement | undefined>
    }
  }
  desktop?: {
    openExternal: (url: string) => Promise<void>
  }
}
