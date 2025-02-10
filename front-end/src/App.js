import "./App.css";
import Header from "./components/Header";
import Swap from "./components/Swap";
import Tokens from "./components/Tokens";
import Pools from "./components/Pools";
import CreatePool from "./components/CreatePool";
import { Routes, Route } from "react-router-dom";
import { useConnect, useAccount } from "wagmi";
import { MetaMaskConnector } from "wagmi/connectors/metaMask";


import { Aptos } from "@aptos-labs/ts-sdk";
export const aptos = new Aptos();
export const moduleAddress = "0x11a2f99a39d339fab5643a9b64a7d94899aa90c02255a72987b18f09cf6147ee";


function App() {
  const { address, isConnected } = useAccount();
  const { connect } = useConnect({
    connector: new MetaMaskConnector(),
  });
  

  return (

    <div className="App">
      <Header connect={connect} isConnected={isConnected} address={address} />
      <div className="mainWindow">
        <Routes>
          <Route path="/" element={<Swap isConnected={isConnected} address={address} />} />
          <Route path="/create" element={<CreatePool />} />
          <Route path="/pools" element={<Pools />} />
        </Routes>
      </div>

    </div>
  )
}

export default App;
