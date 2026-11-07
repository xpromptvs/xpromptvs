import {expect,test} from 'vitest';
import {applyBackgroundColors,backgroundColors,BACKGROUND_COLORS_CHANGED} from '../src/shared/background-colors';
test('background colors accept only full hex colors',()=>{
 expect(backgroundColors({panel:'#ABCDEF',terminal:'#123456'})).toEqual({panel:'#abcdef',terminal:'#123456'});
 expect(backgroundColors({panel:'red',terminal:'#fff; color:red'})).toEqual({});
 expect(backgroundColors(null)).toEqual({});
});
test('background updates and reset are scoped and notify renderer listeners',()=>{
 const root=document.createElement('div'),other=document.createElement('div');
 let events=0;root.addEventListener(BACKGROUND_COLORS_CHANGED,()=>events++);
 applyBackgroundColors(root,{panel:'#123456',terminal:'#654321'});
 expect(root.style.getPropertyValue('--panel-background')).toBe('#123456');
 expect(root.style.getPropertyValue('--terminal-background')).toBe('#654321');
 expect(other.style.getPropertyValue('--panel-background')).toBe('');
 applyBackgroundColors(root,{});
 expect(root.style.getPropertyValue('--panel-background')).toBe('');
 expect(root.style.getPropertyValue('--terminal-background')).toBe('');
 expect(events).toBe(2);
});
