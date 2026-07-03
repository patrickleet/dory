import { FishIcon } from './FishIcon'
import { GithubIcon } from './GithubIcon'

export function Header() {
  return (
    <header>
      <div className="wrap nav">
        <a className="brand" href="#top" aria-label="Dory home">
          <span className="tile">
            <FishIcon />
          </span>
          Dory
        </a>
        <nav className="nav-links">
          <a className="navlink" href="#model">
            How it works
          </a>
          <a className="navlink" href="#features">
            Features
          </a>
          <a className="navlink" href="#devenv">
            Dev&nbsp;envs
          </a>
          <a className="navlink" href="#footprint">
            Footprint
          </a>
          <a className="navlink" href="#install">
            Install
          </a>
          <a
            className="btn btn-ghost"
            href="https://github.com/Augani/dory"
            target="_blank"
            rel="noopener"
            aria-label="Star Dory on GitHub"
          >
            <GithubIcon />
            Star
          </a>
        </nav>
      </div>
    </header>
  )
}
