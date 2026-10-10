import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { initAuth } from './auth.ts'

// Sign in (or skip in local dev) before rendering anything.
void initAuth().then((ready) => {
  if (!ready) return // redirecting to Cognito
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
})
