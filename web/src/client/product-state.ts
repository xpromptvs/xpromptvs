import {productFeatures} from '../shared/product-features';
import type {ViewSetMsg} from './source-picker';
/** Presentation filtering never writes an unsupported view back to the remote host. */
export function supportedViewSet(state:ViewSetMsg):ViewSetMsg {
 if(productFeatures.graphicalAgents)return state;
 return {...state,agents:[],selectedAgent:null,tabOrder:state.tabOrder.filter(key=>!key.startsWith('agent:')),
  view:state.view.surface==='agents'?{surface:'terminal',fullscreen:null}:state.view};
}
